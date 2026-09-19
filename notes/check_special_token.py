"""
Checks whether a literal special-token string (e.g. "</s>") typed into raw
text gets tokenized to the real special-token id, and whether that's the
same id the tokenizer's chat template would insert for the same turn.

Answers the question behind the vort_2b.rb early-EOS bug: is hand-rolling
"</s>" between turns in a raw /v1/completions prompt equivalent to what
/v1/chat_completions would produce via apply_chat_template? See
notes/instruction-tuning-and-tokenizer-templates.md for the full writeup.

Setup (no torch needed, tokenizer-only):
    python3 -m venv venv && ./venv/bin/pip install transformers jinja2 sentencepiece
    ./venv/bin/python notes/check_special_token.py
"""

from transformers import AutoTokenizer

tok = AutoTokenizer.from_pretrained("mistralai/Mistral-7B-Instruct-v0.1")

eos_id = tok.eos_token_id
print("eos_token:", tok.eos_token, "eos_id:", eos_id)

# Simulate what vort_2b.rb builds: literal text containing "</s>" mid-string.
raw = "Hello there</s>[INST] next turn [/INST]"
ids = tok.encode(raw, add_special_tokens=False)
print("\nraw prompt:", repr(raw))
print("ids:", ids)
print("decoded pieces:", [tok.decode([i]) for i in ids])
print("eos_id present in ids?", eos_id in ids)

# Compare against building the same turn via apply_chat_template (what
# /v1/chat_completions does under the hood).
messages = [
    {"role": "user", "content": "first turn"},
    {"role": "assistant", "content": "Hello there"},
    {"role": "user", "content": "next turn"},
]
templated = tok.apply_chat_template(messages, tokenize=True)
templated_ids = templated["input_ids"] if "input_ids" in templated else templated
print("\ntemplated ids:", templated_ids)
print("decoded pieces:", [tok.decode([i]) for i in templated_ids])
print("eos_id present in templated ids?", eos_id in templated_ids)
