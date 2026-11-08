import contextlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from gop_drop import choose_intervals, executable, inputs, main, write_batch


class GOPDropTests(unittest.TestCase):
    def test_evenly_spread_distinct_gops_and_three_groups(self):
        pts = [round(i/24, 6) for i in range(7200)]
        result, tolerance = choose_intervals(list(range(0, 300, 5)), pts, 300, 24)
        self.assertEqual(len(result), 8)
        self.assertEqual(len({x['key'] for x in result}), 8)
        self.assertLess(result[0]['key'], 60)
        self.assertGreater(result[-1]['key'], 240)
        for interval in result:
            near, middle, far = (interval[g] for g in ('near', 'middle', 'far'))
            self.assertLess(near, middle)
            self.assertLess(middle, far)
            self.assertGreater(near-tolerance, interval['key'])
            self.assertLess(far+tolerance, interval['nextKey'])
            self.assertLessEqual(abs(middle-(interval['key']+interval['nextKey'])/2), 1/24)
            self.assertTrue(all(t in pts and t >= 20 and t+15 < 300 for t in (near,middle,far)))

    def test_same_inputs_have_no_random_variation(self):
        pts = [i/24 for i in range(7200)]
        args = (list(range(0, 300, 25)), pts, 300, 24)
        self.assertEqual(choose_intervals(*args), choose_intervals(*args))

    def test_variable_packet_spacing_stays_inside_acceptance_window(self):
        keys = list(range(0, 300, 6))
        pts = set(keys)
        time = 0
        while time < 300:
            pts.add(round(time,6)); time += [.033,.042,.083][len(pts)%3]
        result, tolerance = choose_intervals(keys, sorted(pts), 300, 23.81)
        for interval in result:
            self.assertGreater(interval['near']-tolerance, interval['key'])
            self.assertLess(interval['far']+tolerance, interval['nextKey'])

    def test_short_public_clip_with_one_interior_gop(self):
        result, _ = choose_intervals([0,24,48], [i/24 for i in range(1728)], 72, 24, 1)
        self.assertEqual((result[0]['key'], result[0]['nextKey']), (24,48))

    def test_insufficient_gops_fail_instead_of_reusing_one_interval(self):
        with self.assertRaisesRegex(ValueError, '必要数'):
            choose_intervals([0,24,48], [i/24 for i in range(1728)], 72, 24, 8)

    def test_too_short_gops_cannot_leak_into_next_key(self):
        with self.assertRaises(ValueError):
            choose_intervals([i/10 for i in range(2000)], [i/24 for i in range(4800)], 200, 24)

    def test_three_groups_cannot_share_the_same_acceptance_window(self):
        with self.assertRaises(ValueError):
            choose_intervals([i/2 for i in range(400)], [i/24 for i in range(4800)], 200, 24)

    def test_invalid_rates_keys_and_section_count(self):
        for fps, keys, count in [(0,[0,5],8),(float('nan'),[0,5],8),(24,[5,0],8),(24,[0,5],0),(24,[0,5],17)]:
            with self.subTest(fps=fps,keys=keys,count=count), self.assertRaises(ValueError):
                choose_intervals(keys,[0,5],200,fps,count)

    def test_folder_drop_filters_and_deduplicates_without_recursion(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            movie = root/'日本語 & 100% ! (1).MKV'; movie.write_bytes(b'x')
            (root/'plan.json').write_bytes(b'{}')
            sub = root/'sub'; sub.mkdir(); (sub/'other.mp4').write_bytes(b'x')
            self.assertEqual(inputs([str(root),str(movie)]), [movie.resolve()])

    def test_no_file_or_nonvideo_selection_has_clear_error(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'plan.json'; path.write_bytes(b'{}')
            with self.assertRaises(ValueError):inputs([str(path)])
            with self.assertRaises(ValueError):inputs([str(path.with_name('missing.mp4'))])

    def test_explicit_tool_path_and_no_argument_error(self):
        with tempfile.TemporaryDirectory() as directory:
            tool = Path(directory)/'ffprobe.exe'; tool.write_bytes(b'x')
            self.assertEqual(executable('ffprobe',str(tool)),str(tool.resolve()))
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(main([]),1)

    def test_metadata_batch_has_per_file_targets_and_no_images(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)/'plan.json'
            profiles = [dict(label='a',bytes=1,targets=[24.125]),dict(label='b',bytes=2,targets=[25.125])]
            with contextlib.redirect_stdout(io.StringIO()):
                written = write_batch(profiles,output)
            import json
            data = json.loads(written.read_text(encoding='utf-8'))
            self.assertEqual(data['schema'],2)
            self.assertEqual(data['targets'],[])
            self.assertEqual([p['targets'] for p in data['profiles']],[[24.125],[25.125]])
            self.assertTrue(all('references' not in p for p in data['profiles']))
            original = output.read_bytes()
            with contextlib.redirect_stdout(io.StringIO()):
                another = write_batch(profiles,output)
            self.assertNotEqual(another,output)
            self.assertEqual(output.read_bytes(),original)

    def test_ambiguous_file_sizes_do_not_create_a_plan(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)/'plan.json'
            with self.assertRaises(ValueError):
                write_batch([dict(bytes=1),dict(bytes=1)],output)
            self.assertFalse(output.exists())

    def test_one_failed_input_prevents_partial_batch_export(self):
        with tempfile.TemporaryDirectory() as directory:
            a,b = Path(directory)/'a.mkv',Path(directory)/'b.mkv'
            a.write_bytes(b'a');b.write_bytes(b'bb')
            with patch('gop_drop.executable',return_value='ffprobe'), patch('gop_drop.build_profile',side_effect=[dict(label='a',bytes=1),ValueError('bad video')]), patch('gop_drop.write_batch') as write:
                with contextlib.redirect_stdout(io.StringIO()),contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(main([str(a),str(b)]),1)
                write.assert_not_called()


if __name__ == '__main__':
    unittest.main()
