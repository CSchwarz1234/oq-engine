# Copyright (c) 2010-2014, GEM Foundation.
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

import os
from nose.plugins.attrib import attr

from qa_tests import _utils as qa_utils


# test for a GMPE requiring hypocentral depth, since it was
# broken: https://bugs.launchpad.net/oq-engine/+bug/1334524
class ScenarioHazardCase8TestCase(qa_utils.BaseQATestCase):

    @attr('qa', 'hazard', 'scenario')
    def test(self):
        cfg = os.path.join(os.path.dirname(__file__), 'job.ini')
        self.run_hazard(cfg)
        # I am not checking anything, only that it runs
