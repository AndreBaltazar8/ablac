import math, pathlib, tempfile, struct, unittest, runpy, sys, contextlib, io
from unittest.mock import patch
from stats import Moments,welch,analyze,read_samples
from generate import generate
class Tests(unittest.TestCase):
 def test_welch(self):
  a,b=Moments(),Moments()
  for x in [1,2,3,4]:a.push(x)
  for x in [2,4,6,8]:b.push(x)
  self.assertAlmostEqual(welch(a,b),-2.5/math.sqrt((5/3)/4+(20/3)/4))
 def test_zero_variance(self):
  a,b=Moments(),Moments()
  for _ in range(5):a.push(10);b.push(10)
  self.assertEqual(welch(a,b),0)
  different=Moments()
  for _ in range(5):different.push(11)
  self.assertEqual(welch(a,different),-math.inf)
  b.push(11);self.assertLess(welch(a,b),0)
 def test_control_and_crops(self):
  pilot=[(100+i%50,i%2) for i in range(100)]
  rows=pilot+[(100+(i%2)*1000+i%7,i%2) for i in range(4000)]
  r=analyze(rows,warmup=0,pilot=100,minimum=100)
  self.assertEqual(r['status'],'leak detected');self.assertGreater(r['max_abs_t'],10)
  self.assertEqual(r['samples_valid'],4000)
  swapped=analyze([(x,1-c) for x,c in rows],warmup=0,pilot=100,minimum=100)
  self.assertAlmostEqual(r['max_abs_t'],swapped['max_abs_t'])
  self.assertEqual([t['cut_below_ticks'] for t in r['tests']],[t['cut_below_ticks'] for t in swapped['tests']])
 def test_balanced_and_invalid(self):
  rows=[(100+i%7,c) for i in range(2050) for c in [0,1]]+[(1,2)]
  r=analyze(rows,warmup=0,pilot=100,minimum=100)
  self.assertEqual(r['status'],'no leak detected');self.assertEqual(r['samples_rejected'],1)
  self.assertEqual(analyze(rows,warmup=0,pilot=100,minimum=10000)['status'],'insufficient samples')
 def test_source_binding(self):
  source='before// BEGIN RSA SECRET BIGNUM PRIMITIVES\nsecret core\n// END RSA SECRET BIGNUM PRIMITIVESafter'
  self.assertEqual(generate('driver',source),'driver\n\nsecret core\n')
  self.assertIn('changed core',generate('driver',source.replace('secret core','changed core')))
  with self.assertRaises(ValueError):generate('driver',source.replace('BEGIN RSA','LOST RSA'))
 def test_unsupported_host(self):
  namespace=runpy.run_path(str(pathlib.Path(__file__).with_name('run')),run_name='ct_timing_test')
  with patch('platform.machine',return_value='aarch64'),patch.object(sys,'argv',['run','--cpu','0']),contextlib.redirect_stdout(io.StringIO()) as output:
   self.assertEqual(namespace['main'](),0)
  self.assertIn('unavailable',output.getvalue())
 def test_reader(self):
  with tempfile.TemporaryDirectory() as d:
   p=pathlib.Path(d)/'raw';p.write_bytes(b'ABLATSC1'+struct.pack('<QQQ',1,15,1))
   self.assertEqual(read_samples(p),[(15,1)])
   p.write_bytes(p.read_bytes()[:-1])
   with self.assertRaises(ValueError):read_samples(p)
if __name__=='__main__':unittest.main()
