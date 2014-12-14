# Copyright (c) 2014-2015, GEM Foundation.
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

"""
Core functionality for the classical tilint PSHA hazard calculator.
"""
from multiprocessing.dummy import Pool

from django.db import transaction

from openquake.baselib.general import split_in_blocks, AccumDict
from openquake.hazardlib.site import SiteCollection

from openquake.engine.db import models
from openquake.engine.calculators import calculators
from openquake.engine.calculators.hazard.general import BaseHazardCalculator
from openquake.engine.logs import LOG

POOLSIZE = 16

NTILES = 10


def pre_execute((job, i, tile)):
    """
    :param job: the current job
    :param i: ordinal number of the tile being processed (from 1)
    :param tile: list of sites being processed
    """
    classical = calculators['classical'](job)
    classical.tilepath = ('tile%d' % i,)
    classical.site_collection = SiteCollection(tile)
    classical.parallel_filtering = False
    classical.initialize_sources()
    classical.parse_risk_model()
    return classical


def run_calc(classical):
    """
    """
    classical.init_zeros_ones()
    # reduce the number of tasks for calculations with a small relative weight
    classical.concurrent_tasks *= classical.weight * NTILES
    classical.execute()
    classical.post_execute()
    classical.post_process()


@calculators.add('classical_tiling')
class ClassicalTilingHazardCalculator(BaseHazardCalculator):
    """
    Classical tiling PSHA hazard calculator.
    """
    def pre_execute(self):
        """
        Read the full source model and sites and build the needed tiles
        """
        with transaction.commit_on_success(using='job_init'):
            self.initialize_site_collection()
        self.tiles = list(split_in_blocks(self.site_collection, NTILES))
        self.num_tiles = len(self.tiles)
        LOG.info('Produced %d tiles', self.num_tiles)
        args = ((self.job, i, tile)
                for i, tile in enumerate(self.tiles, 1))
        #for conn in connections.all():
        #    conn.close()
        self.calculators = Pool(POOLSIZE).map(pre_execute, args)
        info = sum((AccumDict(calc.info) for calc in self.calculators), {})
        for calc in self.calculators:
            calc.weight = info['output_weight'] / calc.info['output_weight']
        with transaction.commit_on_success(using='job_init'):
            models.JobInfo.objects.create(
                oq_job=self.job,
                num_sites=info['n_sites'],
                num_realizations=info['max_realizations'],
                num_imts=info['n_imts'],
                num_levels=info['n_levels'],
                input_weight=info['input_weight'],
                output_weight=info['output_weight'])

    def execute(self):
        """
        Executing all tiles sequentially
        """
        Pool(POOLSIZE).map(run_calc, self.calculators)

    def post_execute(self):
        """Do nothing"""

    def post_process(self):
        """Do nothing"""
