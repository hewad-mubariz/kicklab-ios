"""Recheck the historical A13 rewrite against today's pinned 288 function.

No training, thresholds, or application model files are changed. Outputs must
go to a new experiment directory. coremltools and kicklab_lab come from the lab
environment that produced the original compatibility experiment.
"""
import argparse
import hashlib
import json
from pathlib import Path

import coremltools as ct
from coremltools.converters.mil.frontend.milproto.load import load
from kicklab_lab.rfdetr_gpu_compat import rewrite_value_projections


def hashes(path):
    return {str(p.relative_to(path)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(path.rglob('*')) if p.is_file()}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    before = hashes(args.source)
    source = ct.models.MLModel(str(args.source), skip_model_load=True)
    spec = source.get_spec()
    records = []
    for name, rewrite in [('RF288Single', False), ('RF288Compat', True)]:
        program = load(spec, spec.specificationVersion, file_weights_dir=source.weights_dir)
        program.functions = {'main': program.functions['rf288']}
        program.default_function_name = 'main'
        program.export_as_multifunction = False
        contract = [(v.name, tuple(v.shape), str(v.dtype)) for v in program.functions['main'].outputs]
        changes = rewrite_value_projections(program) if rewrite else []
        assert contract == [(v.name, tuple(v.shape), str(v.dtype)) for v in program.functions['main'].outputs]
        model = ct.convert(program, source='milinternal', convert_to='mlprogram',
                           minimum_deployment_target=ct.target.iOS18,
                           compute_precision=ct.precision.FLOAT32,
                           pass_pipeline=ct.PassPipeline.EMPTY, skip_model_load=True)
        output = args.output / (name + '.mlpackage')
        model.save(str(output))
        records.append({'name': name, 'changed_projections': changes, 'files': hashes(output)})
    assert before == hashes(args.source)
    report = {'source': str(args.source.resolve()), 'source_hashes': before,
              'coremltools': ct.__version__, 'function': 'rf288', 'exports': records,
              'training': False, 'production_changed': False,
              'note': 'Same learned values. Repacking changes the weight file layout; phone parity is required.'}
    (args.output / 'export.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
