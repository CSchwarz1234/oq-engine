#!/bin/bash
#
# packager.sh  Copyright (c) 2014, GEM Foundation.
#
# OpenQuake is free software: you can redistribute it and/or modify it
# under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# OpenQuake is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with OpenQuake.  If not, see <http://www.gnu.org/licenses/>.

#
# DESCRIPTION
#
# packager.sh automates procedures to:
#  - test sources
#  - build Ubuntu package (official or development version)
#  - test Ubuntu package
#
# tests are performed inside linux containers (lxc) to achieve
# a good compromise between speed and isolation
#
# all lxc instances are ephemeral
#
# ephemeral containers are "clones" of a base container and have a
# temporary file system that reflects the contents of the base container
# but any modifications are stored in another overlayed
# file system (in-memory or disk)
#

# export PS4='+${BASH_SOURCE}:${LINENO}:${FUNCNAME[0]}: '
if [ $GEM_SET_DEBUG ]; then
    set -x
fi
set -e
GEM_GIT_REPO="git://github.com/gem"
GEM_GIT_PACKAGE="oq-engine"
GEM_GIT_DEPS="oq-hazardlib oq-risklib"
GEM_DEB_PACKAGE="python-${GEM_GIT_PACKAGE}"
GEM_DEB_SERIE="master"
if [ -z "$GEM_DEB_REPO" ]; then
    GEM_DEB_REPO="$HOME/gem_ubuntu_repo"
fi
if [ -z "$GEM_DEB_MONOTONE" ]; then
    GEM_DEB_MONOTONE="$HOME/monotone"
fi

GEM_BUILD_ROOT="build-deb"
GEM_BUILD_SRC="${GEM_BUILD_ROOT}/${GEM_DEB_PACKAGE}"

GEM_MAXLOOP=20

GEM_ALWAYS_YES=false

if [ "$GEM_EPHEM_CMD" = "" ]; then
    GEM_EPHEM_CMD="lxc-start-ephemeral"
fi
GEM_EPHEM_NAME="ubuntu-lxc-eph"

if command -v lxc-shutdown &> /dev/null; then
    # Older lxc (< 1.0.0) with lxc-shutdown
    LXC_TERM="lxc-shutdown -t 10 -w"
    LXC_KILL="lxc-stop"
else
    # Newer lxc (>= 1.0.0) with lxc-stop only
    LXC_TERM="lxc-stop -t 10"
    LXC_KILL="lxc-stop -k"
fi

NL="
"
TB="	"

#
#  functions

#
#  sig_hand - manages cleanup if the build is aborted
#
sig_hand () {
    trap ERR
    echo "signal trapped"
    if [ "$lxc_name" != "" ]; then
        set +e
        scp "${lxc_ip}:/var/tmp/openquake-db-installation" openquake-db-installation
        scp "${lxc_ip}:/tmp/celeryd.log" celeryd.log
        scp "${lxc_ip}:ssh.log" ssh.history
        echo "Destroying [$lxc_name] lxc"
        upper="$(mount | grep "${lxc_name}.*upperdir" | sed 's@.*upperdir=@@g;s@,.*@@g')"
        if [ -f "${upper}.dsk" ]; then
            loop_dev="$(sudo losetup -a | grep "(${upper}.dsk)$" | cut -d ':' -f1)"
        fi
        sudo $LXC_KILL -n $lxc_name
        sudo umount /var/lib/lxc/$lxc_name/rootfs
        sudo umount /var/lib/lxc/$lxc_name/ephemeralbind
        echo "$upper" | grep -q '^/tmp/'
        if [ $? -eq 0 ]; then
            sudo umount "$upper"
            sudo rm -r "$upper"
            if [ "$loop_dev" != "" ]; then
                sudo losetup -d "$loop_dev"
                if [ -f "${upper}.dsk" ]; then
                    sudo rm -f "${upper}.dsk"
                fi
            fi
        fi
        sudo lxc-destroy -n $lxc_name
    fi
    if [ -f /tmp/packager.eph.$$.log ]; then
        rm /tmp/packager.eph.$$.log
    fi
    exit 1
}


#
#  dep2var <dep> - converts in a proper way the name of a dependency to a variable name
#      <dep>    the name of the dependency
#
dep2var () {
    echo "$1" | sed 's/[-.]/_/g;s/\(.*\)/\U\1/g'
}

#
#  repo_id_get - retry git repo from local git remote command
repo_id_get () {
    local repo_name repo_line

    if ! repo_name="$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null)"; then
        repo_line="$(git remote -vv | grep "^origin[ ${TB}]" | grep '(fetch)$')"
        if [ -z "$repo_line" ]; then
            echo "no remote repository associated with the current branch, exit 1"
            exit 1
        fi
    else
        repo_name="$(echo "$repo_name" | sed 's@/.*@@g')"

        repo_line="$(git remote -vv | grep "^${repo_name}[ ${TB}].*(fetch)\$")"
    fi

    if echo "$repo_line" | grep -q '[0-9a-z_-\.]\+@[a-z0-9_-\.]\+:'; then
        repo_id="$(echo "$repo_line" | sed "s/^[^ ${TB}]\+[ ${TB}]\+[^ ${TB}@]\+@//g;s/.git[ ${TB}]\+(fetch)$/.git/g;s@/${GEM_GIT_PACKAGE}.git@@g;s@:@/@g")"
    else
        repo_id="$(echo "$repo_line" | sed "s/^[^ ${TB}]\+[ ${TB}]\+git:\/\///g;s/.git[ ${TB}]\+(fetch)$/.git/g;s@/${GEM_GIT_PACKAGE}.git@@g")"
    fi

    echo "$repo_id"
}

#
#  mksafedir <dname> - try to create a directory and rise an alert if it already exists
#      <dname>    name of the directory to create
#
mksafedir () {
    local dname

    dname="$1"
    if [ "$GEM_ALWAYS_YES" != "true" -a -d "$dname" ]; then
        echo "$dname already exists"
        echo "press Enter to continue or CTRL+C to abort"
        read a
    fi
    rm -rf $dname
    mkdir -p $dname
}

#
#  usage <exitcode> - show usage of the script
#      <exitcode>    value of exitcode
#
usage () {
    local ret

    ret=$1

    echo
    echo "USAGE:"
    echo "    $0 [-D|--development] [-S--sources_copy] [-B|--binaries] [-U|--unsigned] [-R|--repository]    build debian source package."
    echo "       if -S is present try to copy sources to <GEM_DEB_MONOTONE>/source directory"
    echo "       if -B is present binary package is build too."
    echo "       if -R is present update the local repository to the new current package"
    echo "       if -D is present a package with self-computed version is produced."
    echo "       if -U is present no sign are perfomed using gpg key related to the mantainer."
    echo
    echo "    $0 pkgtest <branch-name>"
    echo "                                                 install oq-engine package and related dependencies into"
    echo "                                                 an ubuntu lxc environment and run package tests and demos"

    echo "    $0 devtest <branch-name>"
    echo "                                                 put oq-engine and oq-* dependencies sources in a lxc,"
    echo "                                                 setup environment and run development tests."
    echo
    exit $ret
}

#
#  _wait_ssh <lxc_ip> - wait until the new lxc ssh daemon is ready
#      <lxc_ip>    the IP address of lxc instance
#
_wait_ssh () {
    local lxc_ip="$1"

    for i in $(seq 1 20); do
        if ssh $lxc_ip "echo begin"; then
            break
        fi
        sleep 2
    done
    if [ $i -eq 20 ]; then
        return 1
    fi
}

#
#  _devtest_innervm_run <branch_id> <lxc_ip> - part of source test performed on lxc
#                     the following activities are performed:
#                     - extracts dependencies from oq-{engine,hazardlib, ..} debian/control
#                       files and install them
#                     - builds oq-hazardlib speedups
#                     - installs oq-engine sources on lxc
#                     - set up postgres
#                     - upgrade db
#                     - runs celeryd
#                     - runs tests
#                     - runs coverage
#                     - collects all tests output files from lxc
#
#      <branch_id>    name of the tested branch
#      <lxc_ip>       the IP address of lxc instance
#
_devtest_innervm_run () {
    local i old_ifs pkgs_list dep branch_id="$1" lxc_ip="$2"

    trap 'local LASTERR="$?" ; trap ERR ; (exit $LASTERR) ; return' ERR

    ssh $lxc_ip "rm -f ssh.log"

    ssh $lxc_ip "sudo apt-get update"
    ssh $lxc_ip "sudo apt-get -y upgrade"
    gpg -a --export | ssh $lxc_ip "sudo apt-key add -"
    # install package to manage repository properly
    ssh $lxc_ip "sudo apt-get install -y python-software-properties"

    # add custom packages
    ssh $lxc_ip mkdir -p "repo"
    scp -r ${GEM_DEB_REPO}/custom_pkgs $lxc_ip:repo/custom_pkgs
    ssh $lxc_ip "sudo apt-add-repository \"deb file:/home/ubuntu/repo/custom_pkgs ./\""

    ssh $lxc_ip "sudo apt-get update"
    ssh $lxc_ip "sudo apt-get upgrade -y"

    old_ifs="$IFS"
    IFS=" "
    for dep in $GEM_GIT_DEPS; do
        # extract dependencies for source dependencies
        pkgs_list="$(deps_list "deprec" _jenkins_deps/$dep/debian/control)"
        ssh $lxc_ip "sudo apt-get install -y ${pkgs_list}"

        # install source dependencies
        cd _jenkins_deps/$dep
        git archive --prefix ${dep}/ HEAD | ssh $lxc_ip "tar xv"
        cd -
    done
    IFS="$old_ifs"

    # extract dependencies for this package
    pkgs_list="$(deps_list "all" debian/control)"
    ssh $lxc_ip "sudo apt-get install -y ${pkgs_list}"

    # build oq-hazardlib speedups and put in the right place
    ssh $lxc_ip "set -e
                 cd oq-hazardlib
                 python ./setup.py build
                 for i in \$(find build/ -name *.so); do
                     o=\"\$(echo \"\$i\" | sed 's@^[^/]\+/[^/]\+/@@g')\"
                     cp \$i \$o
                 done"

    # install sources of this package
    git archive --prefix ${GEM_GIT_PACKAGE}/ HEAD | ssh $lxc_ip "tar xv"

    # configure the machine to run tests
    ssh $lxc_ip "set -e
        for dbu in oq_job_init oq_admin; do
            sudo sed -i \"1ilocal   openquake2   \$dbu                   md5\" /etc/postgresql/9.1/main/pg_hba.conf
        done"

    ssh $lxc_ip "sudo service postgresql restart"
    ssh $lxc_ip "set -e ; sudo su postgres -c \"cd oq-engine ; openquake/engine/bin/oq_create_db --yes --db-name=openquake2\""
    ssh $lxc_ip "set -e ; export PYTHONPATH=\"\$PWD/oq-engine:\$PWD/oq-hazardlib:\$PWD/oq-risklib\" ; cd oq-engine ; bin/oq-engine --upgrade-db --yes"

    # run celeryd daemon
    ssh $lxc_ip "export PYTHONPATH=\"\$PWD/oq-engine:\$PWD/oq-hazardlib:\$PWD/oq-risklib\" ; cd oq-engine ; celeryd >/tmp/celeryd.log 2>&1 3>&1 &"

    if [ -z "$GEM_DEVTEST_SKIP_TESTS" ]; then
        # wait for celeryd startup time
        ssh $lxc_ip "
celeryd_wait() {
    local cw_nloop=\"\$1\" cw_ret cw_i

    for cw_i in \$(seq 1 \$cw_nloop); do
        cw_ret=\"\$(celeryctl status)\"
        if echo \"\$cw_ret\" | grep -iq '^error:'; then
            if echo \"\$cw_ret\" | grep -ivq '^error: no nodes replied'; then
                return 1
            fi
        else
            return 0
        fi
        sleep 1
    done

    return 1
}

celeryd_wait $GEM_MAXLOOP"

        # run tests (in this case we omit 'set -e' to be able to read all tests outputs)
        ssh $lxc_ip "export PYTHONPATH=\"\$PWD/oq-engine:\$PWD/oq-hazardlib:\$PWD/oq-risklib\" ;
                 cd oq-engine
                 DJANGO_SETTINGS_MODULE=openquake.server.settings nosetests -v --with-xunit --xunit-file=xunit-server.xml --with-coverage --cover-package=openquake.server --with-doctest openquake/server/tests/
                 nosetests -v --with-xunit --xunit-file=xunit-engine.xml --with-coverage --cover-package=openquake.engine --with-doctest openquake/engine/tests/

                 # OQ Engine QA tests (splitted into multiple execution to track the performance)
                 nosetests  -a 'qa,hazard,classical' -v --with-xunit --xunit-file=xunit-qa-hazard-classical.xml
                 nosetests  -a 'qa,hazard,event_based' -v --with-xunit --xunit-file=xunit-qa-hazard-event-based.xml
                 nosetests  -a 'qa,hazard,disagg' -v --with-xunit --xunit-file=xunit-qa-hazard-disagg.xml
                 nosetests  -a 'qa,hazard,scenario' -v --with-xunit --xunit-file=xunit-qa-hazard-scenario.xml

                 nosetests  -a 'qa,risk,classical' -v --with-xunit --xunit-file=xunit-qa-risk-classical.xml
                 nosetests  -a 'qa,risk,event_based' -v --with-xunit --xunit-file=xunit-qa-risk-event-based.xml
                 nosetests  -a 'qa,risk,classical_bcr' -v --with-xunit --xunit-file=xunit-qa-risk-classical-bcr.xml
                 nosetests  -a 'qa,risk,event_based_bcr' -v --with-xunit --xunit-file=xunit-qa-risk-event-based-bcr.xml
                 nosetests  -a 'qa,risk,scenario_damage' -v --with-xunit --xunit-file=xunit-qa-risk-scenario-damage.xml
                 nosetests  -a 'qa,risk,scenario' -v --with-xunit --xunit-file=xunit-qa-risk-scenario.xml

                 python-coverage xml --include=\"openquake/*\"
        "
        scp "${lxc_ip}:oq-engine/xunit-*.xml" .
        scp "${lxc_ip}:oq-engine/coverage.xml" .
    else
        if [ -d $HOME/fake-data/oq-engine ]; then
            cp $HOME/fake-data/oq-engine/* .
        fi
    fi

    # TODO: version check
#    echo "NOW PRESS ENTER TO CONTINUE"
#    read aaa
    trap ERR

    return
}

#
#  _pkgtest_innervm_run <lxc_ip> - part of package test performed on lxc
#                     the following activities are performed:
#                     - adds local gpg key to apt keystore
#                     - copies 'oq-*' package repositories on lxc
#                     - adds repositories to apt sources on lxc
#                     - performs package tests (install, remove, reinstall ..)
#                     - set up postgres
#                     - upgrade db
#                     - runs celeryd
#                     - executes demos
#
#      <lxc_ip>    the IP address of lxc instance
#
_pkgtest_innervm_run () {
    local lxc_ip="$1" old_ifs

    trap 'local LASTERR="$?" ; trap ERR ; (exit $LASTERR) ; return' ERR

    ssh $lxc_ip "rm -f ssh.log"
    ssh $lxc_ip "sudo apt-get update"
    ssh $lxc_ip "sudo apt-get -y upgrade"
    gpg -a --export | ssh $lxc_ip "sudo apt-key add -"
    # install package to manage repository properly
    ssh $lxc_ip "sudo apt-get install -y python-software-properties"

    # create a remote "local repo" where place $GEM_DEB_PACKAGE package
    ssh $lxc_ip mkdir -p "repo/${GEM_DEB_PACKAGE}"
    scp build-deb/${GEM_DEB_PACKAGE}_*.deb build-deb/${GEM_DEB_PACKAGE}_*.changes \
        build-deb/${GEM_DEB_PACKAGE}_*.dsc build-deb/${GEM_DEB_PACKAGE}_*.tar.gz \
        build-deb/Packages* build-deb/Sources*  build-deb/Release* $lxc_ip:repo/${GEM_DEB_PACKAGE}
    ssh $lxc_ip "sudo apt-add-repository \"deb file:/home/ubuntu/repo/${GEM_DEB_PACKAGE} ./\""

    if [ -f _jenkins_deps_info ]; then
        source _jenkins_deps_info
    fi

    old_ifs="$IFS"
    IFS=" $NL"
    for dep in $GEM_GIT_DEPS; do
        var_pfx="$(dep2var "$dep")"
        var_repo="${var_pfx}_REPO"
        var_branch="${var_pfx}_BRANCH"
        if [ "${!var_repo}" != "" ]; then
            repo="${!var_repo}"
        else
            repo="$GEM_GIT_REPO"
        fi
        if [ "${!var_branch}" != "" ]; then
            branch="${!var_branch}"
        else
            branch="master"
        fi

        if [ "$repo" = "$GEM_GIT_REPO" -a "$branch" = "master" ]; then
            GEM_DEB_SERIE="master"
        else
            GEM_DEB_SERIE="devel/$(echo "$repo" | sed 's@^.*://@@g;s@/@__@g;s/\./-/g')__${branch}"
        fi
        scp -r ${GEM_DEB_REPO}/${GEM_DEB_SERIE}/python-${dep} $lxc_ip:repo/
        ssh $lxc_ip "sudo apt-add-repository \"deb file:/home/ubuntu/repo/python-${dep} ./\""
    done
    IFS="$old_ifs"

    # add custom packages
    scp -r ${GEM_DEB_REPO}/custom_pkgs $lxc_ip:repo/custom_pkgs
    ssh $lxc_ip "sudo apt-add-repository \"deb file:/home/ubuntu/repo/custom_pkgs ./\""

    ssh $lxc_ip "sudo apt-get update"
    ssh $lxc_ip "sudo apt-get upgrade -y"

    # packaging related tests (install, remove, purge, install, reinstall)
    ssh $lxc_ip "sudo apt-get install -y ${GEM_DEB_PACKAGE}"
    ssh $lxc_ip "sudo apt-get remove -y ${GEM_DEB_PACKAGE}"
    ssh $lxc_ip "sudo apt-get install -y ${GEM_DEB_PACKAGE}"
    ssh $lxc_ip "sudo apt-get install --reinstall -y ${GEM_DEB_PACKAGE}"

    # configure the machine to run tests
    ssh $lxc_ip "sudo service postgresql restart"
    # XXX: should the --upgrade-db command go in the postint script?
    ssh $lxc_ip "set -e; oq-engine --upgrade-db --yes"

    # run celeryd daemon
    ssh $lxc_ip "cd /usr/openquake/engine ; celeryd >/tmp/celeryd.log 2>&1 3>&1 &"

    if [ -z "$GEM_PKGTEST_SKIP_DEMOS" ]; then
        # run all of the hazard and risk demos
        ssh $lxc_ip "set -e ; cd /usr/share/doc/python-oq-risklib/examples/demos
        for ini in \$(find . -name job.ini | sort); do
            echo \"Running \$ini\"
            for loop in \$(seq 1 $GEM_MAXLOOP); do
                set +e
                oq-engine --run-hazard  \$ini --exports xml -l info
                oq_ret=\$?
                set -e
                if [ \$oq_ret -eq 0 ]; then
                    break
                elif [ \$oq_ret -ne 2 ]; then
                    exit \$oq_ret
                fi
                sleep 1
            done
            if [ \$loop -eq $GEM_MAXLOOP ]; then
                exit \$oq_ret
            fi
        done

        for demo_dir in \$(find . -mindepth 1 -maxdepth 1 -type d | sort); do
            if [ -f \$demo_dir/job_hazard.ini ]; then
            cd \$demo_dir
            echo \"Running \$demo_dir/job_hazard.ini\"
            oq-engine --run-hazard job_hazard.ini -l info
            job_id=\$(oq-engine --list-hazard-calculations | tail -1 | awk '{print \$1}')
            echo \"Running \$demo_dir/job_risk.ini\"
            oq-engine --run-risk job_risk.ini --exports xml,csv --hazard-calculation-id \$job_id -l info
            cd -
            fi
        done"
    fi
    ssh $lxc_ip "oq-engine --make-html-report today"
    scp "${lxc_ip}:jobs-*.html" .

    scp -r "$lxc_ip:/usr/share/doc/${GEM_DEB_PACKAGE}/changelog*" .

    trap ERR

    return
}

#
#  deps_list <listtype> <filename> - retrieve dependencies list from debian/control
#                                    to be able to install them without the package
#      listtype    inform deps_list which control lines use to get dependencies
#      filename    control file used for input
#
deps_list() {
    local old_ifs out_list skip i d listtype="$1" filename="$2"

    out_list=""
    if [ "$listtype" = "all" ]; then
        in_list="$(cat "$filename" | egrep '^Depends:|^Recommends:|Build-Depends:' | sed 's/^\(Build-\)\?Depends://g;s/^Recommends://g' | tr '\n' ',')"
    elif [  "$listtype" = "deprec" ]; then
        in_list="$(cat "$filename" | egrep '^Depends:|^Recommends:' | sed 's/^Depends://g;s/^Recommends://g' | tr '\n' ',')"
    elif [  "$listtype" = "build" ]; then
        in_list="$(cat "$filename" | egrep '^Depends:|^Build-Depends:' | sed 's/^\(Build-\)\?Depends://g' | tr '\n' ',')"
    else
        in_list="$(cat "$filename" | egrep "^Depends:" | sed 's/^Depends: //g')"
    fi

    old_ifs="$IFS"
    IFS=','
    for i in $in_list ; do
        item="$(echo "$i" |  sed 's/^ \+//g;s/ \+$//g')"
        pkg_name="$(echo "${item} " | cut -d ' ' -f 1)"
        pkg_vers="$(echo "${item} " | cut -d ' ' -f 2)"
        echo "[$pkg_name][$pkg_vers]" >&2
        if echo "$pkg_name" | grep -q "^\${" ; then
            continue
        fi
        skip=0
        for d in $(echo "$GEM_GIT_DEPS" | sed 's/ /,/g'); do
            if [ "$pkg_name" = "python-${d}" ]; then
                skip=1
                break
            fi
        done
        if [ $skip -eq 1 ]; then
            continue
        fi

        if [ "$out_list" = "" ]; then
            out_list="$pkg_name"
        else
            out_list="$out_list $pkg_name"
        fi
    done
    IFS="$old_ifs"

    echo "$out_list"

    return 0
}

#
#  _lxc_name_and_ip_get <filename> - retrieve name and ip of the runned ephemeral lxc and
#                                    put them into global vars "lxc_name" and "lxc_ip"
#      <filename>    file where lxc-start-ephemeral output is saved
#
_lxc_name_and_ip_get()
{
    local filename="$1" i e

    i=-1
    e=-1
    for i in $(seq 1 40); do
        sleep 2
        if grep -q "sudo lxc-console -n $GEM_EPHEM_NAME" $filename 2>&1 ; then
            lxc_name="$(grep "sudo lxc-console -n $GEM_EPHEM_NAME" $filename | sed "s/.*sudo lxc-console -n \($GEM_EPHEM_NAME\)/\1/g")"
            for e in $(seq 1 40); do
                sleep 2
                if grep -q "$lxc_name" /var/lib/misc/dnsmasq*.leases ; then
                    lxc_ip="$(grep " $lxc_name " /var/lib/misc/dnsmasq*.leases | tail -n 1 | cut -d ' ' -f 3)"
                    break
                fi
            done
            break
        fi
    done
    if [ $i -eq 40 -o $e -eq 40 ]; then
        return 1
    fi
    echo "SUCCESSFULLY RUNNED $lxc_name ($lxc_ip)"

    return 0
}

#
#  devtest_run <branch_id> - main function of source test
#      <branch_id>    name of the tested branch
#
devtest_run () {
    local deps old_ifs branch_id="$1"

    mkdir _jenkins_deps

    #
    #  dependencies repos
    #
    # in test sources different repositories and branches can be tested
    # consistently: for each openquake dependency it try to use
    # the same repository and the same branch OR the gem repository
    # and the same branch OR the gem repository and the "master" branch
    #
    repo_id="$(repo_id_get)"
    if [ "$repo_id" != "$GEM_GIT_REPO" ]; then
        repos="git://${repo_id} ${GEM_GIT_REPO}"
    else
        repos="${GEM_GIT_REPO}"
    fi
    old_ifs="$IFS"
    IFS=" "
    for dep in $GEM_GIT_DEPS; do
        found=0
        branch="$branch_id"
        for repo in $repos; do
            # search of same branch in same repo or in GEM_GIT_REPO repo
            if git ls-remote --heads $repo/${dep}.git | grep -q "refs/heads/$branch" ; then
                git clone --depth=1 -b $branch $repo/${dep}.git _jenkins_deps/$dep
                found=1
                break
            fi
        done
        # if not found it fallback in master branch of GEM_GIT_REPO repo
        if [ $found -eq 0 ]; then
            git clone --depth=1 $repo/${dep}.git _jenkins_deps/$dep
            branch="master"
        fi
        cd _jenkins_deps/$dep
        commit="$(git log -1 | grep '^commit' | sed 's/^commit //g')"
        cd -
        echo "dependency: $dep"
        echo "repo:       $repo"
        echo "branch:     $branch"
        echo "commit:     $commit"
        echo
        var_pfx="$(dep2var "$dep")"
        echo "${var_pfx}_COMMIT=$commit" >> _jenkins_deps_info
        echo "${var_pfx}_REPO=$repo"     >> _jenkins_deps_info
        echo "${var_pfx}_BRANCH=$branch" >> _jenkins_deps_info
    done
    IFS="$old_ifs"

    sudo echo
    sudo ${GEM_EPHEM_CMD} -o $GEM_EPHEM_NAME -d 2>&1 | tee /tmp/packager.eph.$$.log &
    _lxc_name_and_ip_get /tmp/packager.eph.$$.log
    rm /tmp/packager.eph.$$.log

    _wait_ssh $lxc_ip
    set +e
    _devtest_innervm_run "$branch_id" "$lxc_ip"
    inner_ret=$?

    scp "${lxc_ip}:/var/tmp/openquake-db-installation" openquake-db-installation.dev || true
    scp "${lxc_ip}:/tmp/celeryd.log" celeryd.log
    scp "${lxc_ip}:ssh.log" devtest.history

    sudo $LXC_TERM -n $lxc_name

    # NOTE: pylint returns errors too frequently to consider them a critical event
    if pylint --rcfile pylintrc -f parseable openquake > pylint.txt ; then
        echo "pylint exits without errors"
    else
        echo "WARNING: pylint exits with $? value"
    fi
    set -e

    # if [ $inner_ret -ne 0 ]; then
    return $inner_ret
    # fi
}

#
#  pkgtest_run <branch_id> - main function of package test
#      <branch_id>    name of the tested branch
#
pkgtest_run () {
    local i e branch_id="$1"

    #
    #  run build of package
    if [ -d build-deb ]; then
        if [ ! -f build-deb/${GEM_DEB_PACKAGE}_*.deb ]; then
            echo "'build-deb' directory already exists but .deb file package was not found"
            return 1

        fi
    else
        $0 $BUILD_FLAGS
    fi

    #
    #  prepare repo and install $GEM_DEB_PACKAGE package
    cd build-deb
    dpkg-scanpackages . /dev/null >Packages
    cat Packages | gzip -9c > Packages.gz
    dpkg-scansources . > Sources
    cat Sources | gzip > Sources.gz
    cat > Release <<EOF
Archive: precise
Origin: Ubuntu
Label: Local Ubuntu Precise Repository
Architecture: amd64
MD5Sum:
EOF
    printf ' '$(md5sum Packages | cut --delimiter=' ' --fields=1)' %16d Packages\n' \
        $(wc --bytes Packages | cut --delimiter=' ' --fields=1) >> Release
    printf ' '$(md5sum Packages.gz | cut --delimiter=' ' --fields=1)' %16d Packages.gz\n' \
        $(wc --bytes Packages.gz | cut --delimiter=' ' --fields=1) >> Release
    printf ' '$(md5sum Sources | cut --delimiter=' ' --fields=1)' %16d Sources\n' \
        $(wc --bytes Sources | cut --delimiter=' ' --fields=1) >> Release
    printf ' '$(md5sum Sources.gz | cut --delimiter=' ' --fields=1)' %16d Sources.gz\n' \
        $(wc --bytes Sources.gz | cut --delimiter=' ' --fields=1) >> Release
    gpg --armor --detach-sign --output Release.gpg Release
    cd -

    sudo echo
    sudo ${GEM_EPHEM_CMD} -o $GEM_EPHEM_NAME -d 2>&1 | tee /tmp/packager.eph.$$.log &
    _lxc_name_and_ip_get /tmp/packager.eph.$$.log
    rm /tmp/packager.eph.$$.log

    _wait_ssh $lxc_ip

    set +e
    _pkgtest_innervm_run $lxc_ip
    inner_ret=$?

    scp "${lxc_ip}:/var/tmp/openquake-db-installation" openquake-db-installation.pkg || true
    scp "${lxc_ip}:/tmp/celeryd.log" celeryd.log
    scp "${lxc_ip}:ssh.log" pkgtest.history

    sudo $LXC_TERM -n $lxc_name
    set -e

    if [ $inner_ret -ne 0 ]; then
        return $inner_ret
    fi

    #
    # in build Ubuntu package each branch package is saved in a separated
    # directory with a well known name syntax to be able to use
    # correct dependencies during the "test Ubuntu package" procedure
    #
    if [ $BUILD_REPOSITORY -eq 1 -a -d "${GEM_DEB_REPO}" ]; then
        if [ "$branch_id" != "" ]; then
            repo_id="$(repo_id_get)"
            if [ "git://$repo_id" != "$GEM_GIT_REPO" -o "$branch_id" != "master" ]; then
                CUSTOM_SERIE="devel/$(echo "$repo_id" | sed "s@/@__@g;s/\./-/g")__${branch_id}"
                if [ "$CUSTOM_SERIE" != "" ]; then
                    GEM_DEB_SERIE="$CUSTOM_SERIE"
                fi
            fi
        fi
        mkdir -p "${GEM_DEB_REPO}/${GEM_DEB_SERIE}"
        repo_tmpdir="$(mktemp -d "${GEM_DEB_REPO}/${GEM_DEB_SERIE}/${GEM_DEB_PACKAGE}.XXXXXX")"

        # if the monotone directory exists and is the "gem" repo and is the "master" branch then ...
        if [ -d "${GEM_DEB_MONOTONE}/binary" ]; then
            if [ "git://$repo_id" == "$GEM_GIT_REPO" -a "$branch_id" == "master" ]; then
                cp build-deb/${GEM_DEB_PACKAGE}_*.deb build-deb/${GEM_DEB_PACKAGE}_*.changes \
                    build-deb/${GEM_DEB_PACKAGE}_*.dsc build-deb/${GEM_DEB_PACKAGE}_*.tar.gz \
                    "${GEM_DEB_MONOTONE}/binary"
                PKG_COMMIT="$(git rev-parse HEAD | cut -c 1-7)"
                grep '_COMMIT' _jenkins_deps_info \
                  | sed 's/\(^.*=[0-9a-f]\{7\}\).*/\1/g' \
                  > "${GEM_DEB_MONOTONE}"/${GEM_DEB_PACKAGE}_${PKG_COMMIT}_deps.txt
            fi
        fi

        cp build-deb/${GEM_DEB_PACKAGE}_*.deb build-deb/${GEM_DEB_PACKAGE}_*.changes \
            build-deb/${GEM_DEB_PACKAGE}_*.dsc build-deb/${GEM_DEB_PACKAGE}_*.tar.gz \
            build-deb/Packages* build-deb/Sources* build-deb/Release* "${repo_tmpdir}"
        if [ "${GEM_DEB_REPO}/${GEM_DEB_SERIE}/${GEM_DEB_PACKAGE}" ]; then
            rm -rf "${GEM_DEB_REPO}/${GEM_DEB_SERIE}/${GEM_DEB_PACKAGE}"
        fi
        mv "${repo_tmpdir}" "${GEM_DEB_REPO}/${GEM_DEB_SERIE}/${GEM_DEB_PACKAGE}"
        echo "The package is saved here: ${GEM_DEB_REPO}/${GEM_DEB_SERIE}/${GEM_DEB_PACKAGE}"
    fi

    return 0
}

#
#  MAIN
#
BUILD_SOURCES_COPY=0
BUILD_BINARIES=0
BUILD_REPOSITORY=0
BUILD_DEVEL=0
BUILD_UNSIGN=0
BUILD_FLAGS=""

trap sig_hand SIGINT SIGTERM
#  args management
while [ $# -gt 0 ]; do
    case $1 in
        -D|--development)
            BUILD_DEVEL=1
            if [ "$DEBFULLNAME" = "" -o "$DEBEMAIL" = "" ]; then
                echo
                echo "error: set DEBFULLNAME and DEBEMAIL environment vars and run again the script"
                echo
                exit 1
            fi
            ;;
        -S|--sources_copy)
            BUILD_SOURCES_COPY=1
            ;;
        -B|--binaries)
            BUILD_BINARIES=1
            ;;
        -R|--repository)
            BUILD_REPOSITORY=1
            ;;
        -U|--unsigned)
            BUILD_UNSIGN=1
            ;;
        -h|--help)
            usage 0
            break
            ;;
        devtest)
            # Sed removes 'origin/' from the branch name
            devtest_run $(echo "$2" | sed 's@.*/@@g')
            exit $?
            break
            ;;
        pkgtest)
            # Sed removes 'origin/' from the branch name
            pkgtest_run $(echo "$2" | sed 's@.*/@@g')
            exit $?
            break
            ;;
        *)
            usage 1
            break
            ;;
    esac
    BUILD_FLAGS="$BUILD_FLAGS $1"
    shift
done

DPBP_FLAG=""
if [ $BUILD_BINARIES -eq 0 ]; then
    DPBP_FLAG="-S"
fi
if [ $BUILD_UNSIGN -eq 1 ]; then
    DPBP_FLAG="$DPBP_FLAG -us -uc"
fi

mksafedir "$GEM_BUILD_ROOT"
mksafedir "$GEM_BUILD_SRC"

git archive HEAD | (cd "$GEM_BUILD_SRC" ; tar xv)

# NOTE: if in the future we need modules we need to execute the following commands
#
# git submodule init
# git submodule update
##  "submodule foreach" vars: $name, $path, $sha1 and $toplevel:
# git submodule foreach "git archive HEAD | (cd \"\${toplevel}/${GEM_BUILD_SRC}/\$path\" ; tar xv ) "

cd "$GEM_BUILD_SRC"

# date
dt="$(date +%s)"

# version info from openquake/engine/__init__.py
ini_vers="$(cat openquake/engine/__init__.py | sed -n "s/^__version__[  ]*=[    ]*['\"]\([^'\"]\+\)['\"].*/\1/gp")"
ini_maj="$(echo "$ini_vers" | sed -n 's/^\([0-9]\+\).*/\1/gp')"
ini_min="$(echo "$ini_vers" | sed -n 's/^[0-9]\+\.\([0-9]\+\).*/\1/gp')"
ini_bfx="$(echo "$ini_vers" | sed -n 's/^[0-9]\+\.[0-9]\+\.\([0-9]\+\).*/\1/gp')"
ini_suf="$(echo "$ini_vers" | sed -n 's/^[0-9]\+\.[0-9]\+\.[0-9]\+\(.*\)/\1/gp')"
# echo "ini [] [$ini_maj] [$ini_min] [$ini_bfx] [$ini_suf]"

# version info from debian/changelog
h="$(grep "^$GEM_DEB_PACKAGE" debian/changelog | head -n 1)"
# pkg_vers="$(echo "$h" | cut -d ' ' -f 2 | cut -d '(' -f 2 | cut -d ')' -f 1 | sed -n 's/[-+].*//gp')"
pkg_name="$(echo "$h" | cut -d ' ' -f 1)"
pkg_vers="$(echo "$h" | cut -d ' ' -f 2 | cut -d '(' -f 2 | cut -d ')' -f 1)"
pkg_rest="$(echo "$h" | cut -d ' ' -f 3-)"
pkg_maj="$(echo "$pkg_vers" | sed -n 's/^\([0-9]\+\).*/\1/gp')"
pkg_min="$(echo "$pkg_vers" | sed -n 's/^[0-9]\+\.\([0-9]\+\).*/\1/gp')"
pkg_bfx="$(echo "$pkg_vers" | sed -n 's/^[0-9]\+\.[0-9]\+\.\([0-9]\+\).*/\1/gp')"
pkg_deb="$(echo "$pkg_vers" | sed -n 's/^[0-9]\+\.[0-9]\+\.[0-9]\+\(-[^+]\+\).*/\1/gp')"
pkg_suf="$(echo "$pkg_vers" | sed -n 's/^[0-9]\+\.[0-9]\+\.[0-9]\+-[^+]\+\(+.*\)/\1/gp')"
# echo "pkg [$pkg_vers] [$pkg_maj] [$pkg_min] [$pkg_bfx] [$pkg_deb] [$pkg_suf]"

if [ $BUILD_DEVEL -eq 1 ]; then
    hash="$(git log --pretty='format:%h' -1)"
    mv debian/changelog debian/changelog.orig
    cp debian/control debian/control.orig
    for dep in $GEM_GIT_DEPS; do
        sed -i "s/\(python-${dep}\) \(([<>=]\+\) \([^)]\+\)\()\)/\1 \2 \3~dev0\4/g"  debian/control
    done

    if [ "$pkg_maj" = "$ini_maj" -a "$pkg_min" = "$ini_min" -a \
         "$pkg_bfx" = "$ini_bfx" -a "$pkg_deb" != "" ]; then
        deb_ct="$(echo "$pkg_deb" | sed 's/^-//g')"
        pkg_deb="-$(( deb_ct ))"
    else
        pkg_maj="$ini_maj"
        pkg_min="$ini_min"
        pkg_bfx="$ini_bfx"
        pkg_deb="-0"
    fi

    ( echo "$pkg_name (${pkg_maj}.${pkg_min}.${pkg_bfx}${pkg_deb}~dev${dt}-${hash}) $pkg_rest"
      echo
      echo "  [Automatic Script]"
      echo "  * Development version from $hash commit"
      echo
      cat debian/changelog.orig | sed -n "/^$GEM_DEB_PACKAGE/q;p"
      echo " -- $DEBFULLNAME <$DEBEMAIL>  $(date -d@$dt -R)"
      echo
    )  > debian/changelog
    cat debian/changelog.orig | sed -n "/^$GEM_DEB_PACKAGE/,\$ p" >> debian/changelog
    rm debian/changelog.orig

    sed -i "s/^__version__[  ]*=.*/__version__ = '${pkg_maj}.${pkg_min}.${pkg_bfx}${pkg_deb}~dev${dt}-${hash}'/g" openquake/engine/__init__.py
fi

if [  "$ini_maj" != "$pkg_maj" -o \
      "$ini_min" != "$pkg_min" -o \
      "$ini_bfx" != "$pkg_bfx" ]; then
    echo
    echo "Versions are not aligned"
    echo "    init:  ${ini_maj}.${ini_min}.${ini_bfx}"
    echo "    pkg:   ${pkg_maj}.${pkg_min}.${pkg_bfx}"
    echo
    echo "press [enter] to continue, [ctrl+c] to abort"
    read a
fi

sed -i "s/^\([ ${TB}]*\)[^)]*\()  # release date .*\)/\1${dt}\2/g" openquake/__init__.py

# mods pre-packaging
mv LICENSE         openquake/engine
mv README.md       openquake/engine/README
mv celeryconfig.py openquake/engine
mv openquake.cfg   openquake/engine

dpkg-buildpackage $DPBP_FLAG
cd -

# if the monotone directory exists and is the "gem" repo and is the "master" branch then ...
if [ -d "${GEM_DEB_MONOTONE}/source" -a $BUILD_SOURCES_COPY -eq 1 ]; then
    cp build-deb/${GEM_DEB_PACKAGE}_*.changes \
        build-deb/${GEM_DEB_PACKAGE}_*.dsc build-deb/${GEM_DEB_PACKAGE}_*.tar.gz \
        "${GEM_DEB_MONOTONE}/source"
fi

if [ $BUILD_DEVEL -ne 1 ]; then
    exit 0
fi

#
# DEVEL EXTRACTION OF SOURCES
if [ -z "$GEM_SRC_PKG" ]; then
    echo "env var GEM_SRC_PKG not set, exit"
    exit 0
fi
GEM_BUILD_PKG="${GEM_SRC_PKG}/pkg"
mksafedir "$GEM_BUILD_PKG"
GEM_BUILD_EXTR="${GEM_SRC_PKG}/extr"
mksafedir "$GEM_BUILD_EXTR"
cp  ${GEM_BUILD_ROOT}/${GEM_DEB_PACKAGE}_*.deb  $GEM_BUILD_PKG
cd "$GEM_BUILD_EXTR"
dpkg -x $GEM_BUILD_PKG/${GEM_DEB_PACKAGE}_*.deb .
dpkg -e $GEM_BUILD_PKG/${GEM_DEB_PACKAGE}_*.deb
