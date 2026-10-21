import copy
import json

import numpy as np
import torch
from conftest import tiny

from convert import Padded, convert_task
from coreml_runtime import CoreMLBackend

SHAPES = (64, 128)


def test_the_core_ml_function_pads_and_matches_pytorch(tmp_path) -> None:
    tagger = tiny(("question",))
    reference = copy.deepcopy(tagger)
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    convert_task(tagger, "question", SHAPES, tmp_path, scratch)
    (tmp_path / "settings.json").write_text(
        json.dumps({"shapes": {"question": list(SHAPES)}, "pad_token_id": 0})
    )
    backend = CoreMLBackend(tmp_path, "cpu")
    for length in (100, 128, 40):
        ids = torch.tensor([[i % 900 + 5 for i in range(length)]])
        with torch.no_grad():
            expected = reference(ids, torch.ones_like(ids), "question")[0].numpy()
        got = backend.logits("question", ids[0].tolist())
        assert got.shape == expected.shape
        assert np.abs(got - expected).max() < 0.05
        assert (got.argmax(-1) == expected.argmax(-1)).mean() > 0.95
    backend.pad_id = 7
    assert np.abs(backend.logits("question", ids[0].tolist()) - got).max() < 1e-3


def test_the_mask_hides_the_padding_and_the_test_can_tell() -> None:
    wrapper = Padded(tiny(("question",)), "question").eval()
    real = torch.tensor([[i % 900 + 5 for i in range(40)]])
    padded = [torch.cat([real, torch.full((1, 24), v)], dim=1) for v in (0, 7)]
    mask = torch.cat([torch.ones(1, 40), torch.zeros(1, 24)], dim=1).long()
    with torch.no_grad():
        masked = [wrapper(ids, mask)[0, :40] for ids in padded]
        unmasked = [wrapper(ids, torch.ones_like(mask))[0, :40] for ids in padded]
    assert (masked[0] - masked[1]).abs().max() < 1e-5
    assert (unmasked[0] - unmasked[1]).abs().max() > 1e-4
