UV = uv run
SEEDS = 0 1 2
MODEL ?= data/output/mixed-nobold-s0

.PHONY: test data plan synthetic redact label eval-label eval-set split pipeline manifest report sanity diagnostic train train-ettin train-mixed train-createml eval eval-ettin eval-mixed eval-createml convert bench tokens swift-offsets

test:
	$(UV) pytest -q
	$(UV) ruff check .

data: data/contexts.jsonl

data/contexts.jsonl: render.py redact.py
	$(UV) python render.py

plan: data/plan.stamp

data/plan.stamp: data/contexts.jsonl split.py validate.py render.py
	$(UV) python split.py --plan
	touch $@

data/contexts-train.jsonl data/contexts-train-variants.jsonl data/contexts-eval-real.jsonl data/contexts-eval-real-variants.jsonl data/contexts-ask.jsonl: data/plan.stamp

synthetic: data/synthetic/train.jsonl data/synthetic/eval.jsonl

data/synthetic.stamp: synthetic.py render.py validate.py
	$(UV) python synthetic.py
	touch $@

data/synthetic/train.jsonl data/synthetic/eval.jsonl: data/synthetic.stamp

redact:
	$(UV) pytest -q tests/test_redact.py

label: data/labels-train.jsonl

data/labels-train.jsonl: data/contexts-train.jsonl label.py redact.py validate.py render.py
	$(UV) python label.py --stage train --input data/contexts-train.jsonl --output data/labels-train.jsonl --resume

eval-label: data/labels-eval-real.jsonl

data/labels-eval-real.jsonl: data/contexts-eval-real.jsonl label.py redact.py validate.py render.py
	$(UV) python label.py --stage eval-real --input data/contexts-eval-real.jsonl --output data/labels-eval-real.jsonl --model pro --samples 5 --resume

data/eval-real-samples.jsonl: data/labels-eval-real.jsonl
	@test -f $@ || (echo "missing $@; rerun make data/labels-eval-real.jsonl" >&2; exit 1)

eval-set: data/eval-parts.jsonl

data/eval-parts.jsonl: data/contexts-ask.jsonl data/contexts-eval-real.jsonl data/contexts-eval-real-variants.jsonl data/labels-eval-real.jsonl data/eval-real-samples.jsonl data/synthetic/eval.jsonl data/session-plan.json evalset.py
	$(UV) python evalset.py

split: data/split.stamp

data/split.stamp: data/eval-parts.jsonl data/labels-train.jsonl data/contexts-train.jsonl data/contexts-train-variants.jsonl data/synthetic/train.jsonl split.py validate.py render.py
	$(UV) python split.py
	touch $@

data/train.jsonl data/dev.jsonl data/dev-train.jsonl data/eval.jsonl data/split-meta.json: data/split.stamp

data/render-meta.json: data/contexts.jsonl
	@test -f $@ || (echo "missing $@; rerun make data" >&2; exit 1)

data/session-plan.json: data/plan.stamp
	@test -f $@ || (echo "missing $@; rerun make plan" >&2; exit 1)

data/synthetic-meta.json: data/synthetic.stamp
	@test -f $@ || (echo "missing $@; rerun make synthetic" >&2; exit 1)

data/label-train-meta.json: data/labels-train.jsonl
	@test -f $@ || (echo "missing $@; rerun make label" >&2; exit 1)

data/label-eval-real-meta.json: data/labels-eval-real.jsonl
	@test -f $@ || (echo "missing $@; rerun make eval-label" >&2; exit 1)

data/eval-meta.json: data/eval-parts.jsonl
	@test -f $@ || (echo "missing $@; rerun make eval-set" >&2; exit 1)

manifest: manifest.json

manifest.json: data/split.stamp data/label-train-meta.json data/label-eval-real-meta.json data/eval-meta.json data/synthetic-meta.json data/session-plan.json data/render-meta.json manifest.py label.py render.py
	$(UV) python manifest.py

report: data/phase1-report.md

data/phase1-report.md: manifest.json report.py
	$(UV) python report.py

pipeline: data/phase1-report.md

diagnostic: data/diagnostic-meta.json

data/diagnostic-contexts.jsonl: data/contexts-train.jsonl diagnostic.py
	$(UV) python diagnostic.py --select

data/labels-diagnostic.jsonl: data/diagnostic-contexts.jsonl label.py
	$(UV) python label.py --stage diagnostic --input data/diagnostic-contexts.jsonl --output data/labels-diagnostic.jsonl --model pro --samples 1 --workers 32

data/diagnostic-meta.json: data/labels-diagnostic.jsonl data/labels-train.jsonl diagnostic.py
	$(UV) python diagnostic.py --compare

sanity: data/sanity.json

data/sanity.json: data/split.stamp train.py eval.py
	$(UV) python train.py --backend ettin --train data/train.jsonl --eval data/eval.jsonl --epochs 1 --batch-size 8 --learning-rate 1e-4 --seed 0 --output data/output/sanity-phase1-s0 --no-bold
	$(UV) python eval.py --model data/output/sanity-phase1-s0 --output data/output/sanity-phase1-s0/eval.json
	$(UV) python -c "import json; from pathlib import Path; t=json.loads(Path('data/output/sanity-phase1-s0/training.json').read_text()); e=json.loads(Path('data/output/sanity-phase1-s0/eval.json').read_text()); Path('data/sanity.json').write_text(json.dumps({'train':t['train'],'epochs':t['epochs'],'train_seconds':t['train_seconds'],'question_f1':e['token_f1']['question']['f1'],'option_f1':e['option']['f1'],'unit_accuracy':e['unit_accuracy'],'false_positive_rate':e['question_false_positive_rate'],'real_option_f1':e['parts']['real']['option']['f1']},indent=2)+'\n')"

sweep: data/dev.jsonl data/dev-train.jsonl
	$(UV) python sweep.py

train-ettin:
	for seed in $(SEEDS); do \
		$(UV) python train.py --backend ettin --seed $$seed --output data/output/ettin-bold-s$$seed; \
		$(UV) python train.py --backend ettin --seed $$seed --output data/output/ettin-nobold-s$$seed --no-bold; \
	done

mixed:
	cat data/train.jsonl data/synthetic/train.jsonl > data/mixed-train.jsonl

train-mixed: mixed
	for seed in $(SEEDS); do \
		$(UV) python train.py --backend ettin --train data/mixed-train.jsonl --eval data/eval.jsonl --epochs 20 --batch-size 8 --learning-rate 1e-4 --seed $$seed --output data/output/mixed-bold-s$$seed; \
		$(UV) python train.py --backend ettin --train data/mixed-train.jsonl --eval data/eval.jsonl --epochs 20 --batch-size 8 --learning-rate 1e-4 --seed $$seed --output data/output/mixed-nobold-s$$seed --no-bold; \
	done

eval-mixed:
	for seed in $(SEEDS); do \
		$(UV) python eval.py --model data/output/mixed-bold-s$$seed --output data/output/mixed-bold-s$$seed/eval.json; \
		$(UV) python eval.py --model data/output/mixed-nobold-s$$seed --output data/output/mixed-nobold-s$$seed/eval.json; \
	done

train-createml:
	$(UV) python train.py --backend createml --output data/output/createml-bold
	$(UV) python train.py --backend createml --output data/output/createml-nobold --no-bold

train: train-ettin train-createml

eval-ettin:
	for seed in $(SEEDS); do \
		$(UV) python eval.py --model data/output/ettin-bold-s$$seed; \
		$(UV) python eval.py --model data/output/ettin-nobold-s$$seed; \
	done

eval-createml:
	$(UV) python eval.py --backend createml --model data/output/createml-bold
	$(UV) python eval.py --backend createml --model data/output/createml-nobold

eval: eval-ettin eval-createml

convert:
	$(UV) python convert.py --model $(MODEL) --palettize

bench:
	$(UV) python bench.py

tokens:
	$(UV) python token_counts.py

swift-offsets:
	cd swift-offsets && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
	$(UV) python swift_offsets.py
