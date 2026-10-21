import torch
from conftest import tiny

from model import checkpoint_dir, load_models, load_tokenizer, save


def test_padding_to_a_fixed_shape_with_a_mask_gives_the_same_tags() -> None:
    model = tiny(("question",))
    ids = torch.randint(10, 1000, (1, 37))
    padded = torch.cat([ids, torch.zeros(1, 91, dtype=torch.long)], dim=1)
    mask = torch.cat([torch.ones(1, 37), torch.zeros(1, 91)], dim=1).long()
    with torch.no_grad():
        plain = model(ids, torch.ones_like(ids), "question")[0]
        fixed = model(padded, mask, "question")[0, :37]
    assert torch.allclose(plain, fixed, atol=1e-4)
    assert plain.argmax(-1).tolist() == fixed.argmax(-1).tolist()


def test_checkpoint_layouts(tmp_path) -> None:
    tokenizer = load_tokenizer()
    joint = tiny(("question", "option"))
    save(joint, tokenizer, tmp_path / "joint")
    loaded = load_models(tmp_path / "joint")
    assert set(loaded) == {"question", "option"} and loaded["question"] is loaded["option"]
    save(tiny(("question",)), tokenizer, tmp_path / "two" / "question")
    save(tiny(("option",)), tokenizer, tmp_path / "two" / "option")
    two = load_models(tmp_path / "two")
    assert two["question"] is not two["option"]
    assert list(two["option"].heads) == ["option"]
    assert checkpoint_dir(tmp_path / "two") == tmp_path / "two" / "question"
    assert load_tokenizer(tmp_path / "two").cls_token_id == tokenizer.cls_token_id


def test_a_loaded_checkpoint_has_the_same_logits_as_one_built_the_slow_way(tmp_path) -> None:
    from safetensors.torch import load_file

    from model import WEIGHTS

    tokenizer = load_tokenizer()
    source = tiny(("question", "option"))
    save(source, tokenizer, tmp_path)
    fast = load_models(tmp_path)["question"]
    slow = tiny(("question", "option"))
    slow.load_state_dict(load_file(tmp_path / WEIGHTS))
    ids = torch.randint(10, 1000, (1, 50))
    with torch.no_grad():
        assert torch.equal(
            fast(ids, torch.ones_like(ids), "option"),
            slow.eval()(ids, torch.ones_like(ids), "option"),
        )


def test_a_two_ends_checkpoint_keeps_its_width_and_crf_settings(tmp_path) -> None:
    from conftest import tiny_two_ends

    from crf import Crf
    from model import load_crf, update_settings

    save(tiny_two_ends(), load_tokenizer(), tmp_path / "question")
    assert load_models(tmp_path / "question")["question"].heads["question"].out_features == 6
    assert load_crf(tmp_path) is None
    update_settings(tmp_path, question_threshold=0.8)
    update_settings(tmp_path, crf=Crf().transitions().to_json())
    update_settings(tmp_path, question_threshold=0.7)
    assert load_crf(tmp_path) is not None
    assert load_crf(tmp_path).trans[0, 2] == -float("inf")
