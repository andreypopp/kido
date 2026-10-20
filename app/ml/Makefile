UV = uv run
SEEDS = 0 1 2
MODEL ?= data/output/mixed-nobold-s0

.PHONY: test data synthetic redact label split dev train train-ettin train-mixed train-createml eval eval-ettin eval-mixed eval-createml convert bench tokens manifest swift-offsets sweep curve

test:
	$(UV) pytest -q
	$(UV) ruff check .

data:
	$(UV) python render.py

synthetic:
	$(UV) python synthetic.py

redact:
	$(UV) pytest -q tests/test_redact.py

label:
	$(UV) python label.py

split:
	$(UV) python split.py --labels data/labels.jsonl

dev:
	$(UV) python split.py --dev

sweep: dev
	$(UV) python sweep.py

curve: sweep
	$(UV) python learning_curve.py

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

manifest:
	$(UV) python manifest.py

swift-offsets:
	cd swift-offsets && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
	$(UV) python swift_offsets.py
