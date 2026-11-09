"""Makes reference vectors for the texts in Tests/Reference/texts.json the way vectors.json was made: llama.cpp b11461
(llama-embedding, mean-pooled, L2-normalized) with ggml-org/embeddinggemma-2-GGUF's Q8_0 at bfcd298.

    python3 -I scripts/make_reference_vectors.py --bin <llama.cpp build>/bin --model <embeddinggemma-2-Q8_0.gguf> \
        [--check] [--write Tests/Reference/vectors-extra.json --names name ...]

--check first makes the texts vectors.json already has and compares them with it: the method is the reference's only
if each cosine is ≥ 0.9999. --write makes the named texts and writes them. An input past 2,048 tokens is cut as the
hub's tokenizer cuts it (transformers, truncation=True, max_length=2048): <bos>, the first 2,046 tokens, <eos>. The cut
text is checked to tokenize to exactly those tokens before it's embedded.
"""
import argparse
import json
import math
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REFERENCE = os.path.join(ROOT, "Tests", "Reference")
MAX_TOKENS = 2048
SAME = 0.9999
# llama-embedding splits its input at this (default: every newline); no reference text has it.
SEPARATOR = "<<one input>>"


def tokens(args, text):
    """[(id, piece)] as llama.cpp tokenizes `text`, special tokens included."""
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".txt", delete=False) as f:
        f.write(text)
    try:
        out = subprocess.run([os.path.join(args.bin, "llama-tokenize"), "-m", args.model, "-f", f.name, "--log-disable"],
                             capture_output=True, check=True).stdout.decode("utf-8")
    finally:
        os.unlink(f.name)
    pairs = [(int(m.group(1)), m.group(2)) for m in re.finditer(r"^\s*(\d+) -> '(.*?)'$", out, re.M | re.S)]
    if len(pairs) != out.count(" -> '"):
        sys.exit("couldn't read llama-tokenize's pieces (a piece with a line break?)")
    return pairs


def cut(args, text):
    """`text`, or its start when it runs past MAX_TOKENS: the text of the first MAX_TOKENS - 2 tokens after <bos>."""
    whole = tokens(args, text)
    if len(whole) <= MAX_TOKENS:
        return text
    if whole[-1][1] != "<eos>":
        sys.exit("the tokenizer doesn't end with <eos>: the hub's cut isn't known")
    kept = whole[1:MAX_TOKENS - 1]
    start = "".join(piece for _, piece in kept)
    again = tokens(args, start)
    if [i for i, _ in again] != [whole[0][0]] + [i for i, _ in kept] + [whole[-1][0]]:
        sys.exit("the cut text doesn't tokenize to the first tokens: pick another length")
    print(f"  cut from {len(whole)} tokens to {len(again)}")
    return start


def embed(args, text):
    if SEPARATOR in text:
        sys.exit("an input holds the separator")
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".txt", delete=False) as f:
        f.write(text)
    try:
        out = subprocess.run([os.path.join(args.bin, "llama-embedding"), "-m", args.model, "-f", f.name,
                              "--pooling", "mean", "--embd-normalize", "2", "--embd-output-format", "json",
                              "-c", str(MAX_TOKENS), "-b", str(MAX_TOKENS), "-ub", str(MAX_TOKENS),
                              "--embd-separator", SEPARATOR],
                             capture_output=True, check=True).stdout.decode("utf-8")
    finally:
        os.unlink(f.name)
    data = json.loads(out)["data"]
    if len(data) != 1:
        sys.exit(f"one input made {len(data)} vectors")
    return data[0]["embedding"]


def cosine(a, b):
    return sum(x * y for x, y in zip(a, b)) / math.sqrt(sum(x * x for x in a) * sum(y * y for y in b))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--bin", required=True, help="llama.cpp's build/bin, with llama-embedding and llama-tokenize")
    ap.add_argument("--model", required=True, help="embeddinggemma-2-Q8_0.gguf")
    ap.add_argument("--check", action="store_true", help="first make vectors.json's texts again and compare")
    ap.add_argument("--write", help="where to write the vectors of --names")
    ap.add_argument("--names", nargs="*", default=[])
    args = ap.parse_args()
    with open(os.path.join(REFERENCE, "texts.json"), encoding="utf-8") as f:
        listed = json.load(f)["texts"]
    texts = {t["name"]: t["input"] for t in listed}
    if len(texts) != len(listed):
        sys.exit("texts.json has a name twice")
    if args.write and not args.names:
        sys.exit("--write needs --names")
    with open(os.path.join(REFERENCE, "vectors.json"), encoding="utf-8") as f:
        reference = json.load(f)
    if args.check:
        worst = 1.0
        for name in texts:
            if name in reference["vectors"]:
                c = cosine(embed(args, cut(args, texts[name])), reference["vectors"][name])
                worst = min(worst, c)
                print(f"  {name:16s} {c:.6f}")
        if worst < SAME:
            sys.exit(f"not the reference's method: {worst:.6f} < {SAME}")
    if args.write:
        made = {}
        for name in args.names:
            print(name)
            made[name] = embed(args, cut(args, texts[name]))
        with open(args.write, "w", encoding="utf-8") as f:
            json.dump({"made_with": reference["made_with"], "vector_version": reference["vector_version"],
                       "vectors": made}, f, sort_keys=True)
        print(f"wrote {len(made)} to {args.write}")


if __name__ == "__main__":
    main()
