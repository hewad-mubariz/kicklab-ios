"""Checks for event matching and uncertainty accounting, independent of the counter."""
import unittest
from score import align, score

def event(t,label='valid'):
    return dict(id=str(t),time_s=t,label=label,contact='legal_leg')

def touch(t):
    return dict(timestampMs=round(t*1000),frameIndex=round(t*30))

def labels(events,segments=(),**kwargs):
    return dict(events=events,segments=segments,source_name='test',source_sha256='test',review_status='test',**kwargs)

class MatchingTests(unittest.TestCase):
    def test_one_prediction_cannot_cover_two_contacts(self):
        self.assertEqual(len(align([event(1),event(1.2)],[touch(1.1)])),1)

    def test_maximum_matches_before_minimum_distance(self):
        self.assertEqual(align([event(1),event(1.3)],[touch(.85),touch(1.12)]),((0,0),(1,1)))

    def test_closest_match_and_dense_tolerance(self):
        self.assertEqual(align([event(1)],[touch(.84),touch(1.02)]),((0,1),))
        self.assertEqual(align([event(1)],[touch(1.15)],.12),())

    def test_uncertain_and_unreviewed_are_not_false_positives(self):
        r=score(labels([event(1,'uncertain')]),dict(touches=[touch(1),touch(2)],diagnostics=[]))
        self.assertEqual((r['accepted_valid'],len(r['uncertain_accepted']),len(r['false_accepted']),len(r['unmatched_needing_review'])),(0,1,0,1))

    def test_negative_interval_and_missed_diagnostic(self):
        d=dict(time=1.01,frameIndex=30,rejection='amplitudeTooSmall')
        r=score(labels([event(1)],[dict(start_s=2,end_s=3,label='invalid',reason='ground')]),dict(touches=[touch(2.5)],diagnostics=[d]))
        self.assertEqual(r['missed_valid'][0]['decision']['rejection'],'amplitudeTooSmall')
        self.assertEqual(len(r['false_accepted']),1)

    def test_no_nearby_diagnostic_is_not_a_named_filter(self):
        r=score(labels([event(1)],time_tolerance_s=.12),dict(touches=[],diagnostics=[dict(time=1.15,rejection='groundBounce')]))
        self.assertIsNone(r['missed_valid'][0]['decision'])
        self.assertEqual(r['missed_valid'][0]['stage'],'no_nearby_candidate')

if __name__=='__main__': unittest.main()
