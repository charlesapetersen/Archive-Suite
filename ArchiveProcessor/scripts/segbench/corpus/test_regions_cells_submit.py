"""Submission dry-run is local, bounded and safe at paths with spaces."""
import json
import os
from pathlib import Path
import subprocess
import unittest
import test_regions_cells as F

class Submit(unittest.TestCase):
    setUp=F.Pilot.setUp

    def run_submit(self,dry=True):
        script=Path(__file__).with_name('regions-cells-submit.sh')
        env=dict(os.environ,ARCHIVE_UNATTENDED='1',SCRATCH=str(self.root/'scratch with spaces'),GROUP_HOME=str(self.root/'group with spaces'))
        return subprocess.run(['bash',str(script),str(self.root)]+(['--dry-run'] if dry else []),env=env,text=True,capture_output=True)

    def test_dry_run_exactly_three_jobs_no_expansion_or_writes(self):
        result=self.run_submit();self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stderr.count('sbatch '),3)
        self.assertEqual(result.stderr.count('--partition=gpu'),2)
        self.assertEqual(result.stderr.count('--dependency=afterok:0'),2)
        self.assertEqual(result.stderr.count('--time=01:00:00'),2)
        self.assertNotIn('--phase',result.stderr)
        self.assertFalse((self.root/'scratch with spaces').exists())
        self.assertFalse((self.root/'jobs.tsv').exists())
        self.assertEqual(json.loads(result.stdout)['requests_per_route'],{'whole':2,'table':2,'cell':10})

    def test_engine_cannot_submit_live(self):
        result=self.run_submit(dry=False);self.assertNotEqual(result.returncode,0)
        self.assertIn('owner-attended',result.stdout)
        self.assertFalse((self.root/'scratch with spaces').exists())

    def test_each_script_parses(self):
        for name in ('submit','stage-job','job'):
            p=Path(__file__).with_name('regions-cells-'+name+'.sh')
            result=subprocess.run(['bash','-n',str(p)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)

if __name__=='__main__':unittest.main()
