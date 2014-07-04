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

import os.path
import numpy

from nose.plugins.attrib import attr
from openquake.engine.db import models
from qa_tests import _utils as qa_utils

aaae = numpy.testing.assert_array_almost_equal


# NB: this is a regression test to make sure that the sampling
# works well even for huge source model logic trees, since
# in the past we had issues, https://bugs.launchpad.net/oq-engine/+bug/1312020
class ClassicalHazardCase16TestCase(qa_utils.BaseQATestCase):

    @attr('qa', 'hazard', 'classical')
    def test(self):
        expected_mean_poes = [0.327905527354, 0.324717826053, 0.316179020913]
        expected_q0_1_poes = [0.198642855479, 0.19587955512, 0.188594171735]
        expected_q0_9_poes = [0.585553284108, 0.581083306028, 0.568977776502]

        job = self.run_hazard(
            os.path.join(os.path.dirname(__file__), 'job.ini'))

        # mean
        [mean_curve] = models.HazardCurveData.objects \
            .filter(hazard_curve__output__oq_job=job.id,
                    hazard_curve__statistics='mean')
        aaae(expected_mean_poes, mean_curve.poes, decimal=7)

        # quantiles
        quantile_0_1_curve, quantile_0_9_curve = \
            models.HazardCurveData.objects.filter(
                hazard_curve__output__oq_job=job.id,
                hazard_curve__statistics='quantile').order_by(
                'hazard_curve__quantile')
        aaae(expected_q0_1_poes, quantile_0_1_curve.poes, decimal=7)
        aaae(expected_q0_9_poes, quantile_0_9_curve.poes, decimal=7)
