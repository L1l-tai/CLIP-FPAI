"""CLIP tokenizer: 对齐 test/web_ui/open_clip/tokenizer.py 的 SimpleTokenizer."""
import sys, os, gzip, re
from pathlib import Path
import numpy as np

SOT = 49406
EOT = 49407
MAX_LEN = 77

def bytes_to_unicode():
    bs = (list(range(ord("!"), ord("~")+1))
        + list(range(ord("¡"), ord("¬")+1))
        + list(range(ord("®"), ord("ÿ")+1)))
    cs = bs[:]
    n = 0
    for b in range(2**8):
        if b not in bs:
            bs.append(b)
            cs.append(2**8 + n)
            n += 1
    return dict(zip(bs, [chr(c) for c in cs]))

def get_pairs(word):
    return set(zip(word, word[1:]))

class SimpleTokenizer:
    def __init__(self, bpe_path: str):
        self.byte_encoder = bytes_to_unicode()
        self.byte_decoder = {v: k for k, v in self.byte_encoder.items()}

        merges_raw = gzip.open(bpe_path).read().decode("utf-8").split('\n')
        # 只取前 49152-256-2+1 条 (对齐 web_ui)
        merges = merges_raw[1:49152-256-2+1]
        merges = [tuple(m.split()) for m in merges]

        # 构建 vocab: bytes_to_unicode 的值 + </w> 版本 + merges + specials
        vocab = list(bytes_to_unicode().values())
        vocab = vocab + [v + '</w>' for v in vocab]
        for merge in merges:
            vocab.append(''.join(merge))
        special_tokens = ['<start_of_text>', '<end_of_text>']
        vocab.extend(special_tokens)

        self.encoder = dict(zip(vocab, range(len(vocab))))
        self.bpe_ranks = dict(zip(merges, range(len(merges))))
        self.cache = {t: t for t in special_tokens}

        special = "|".join(special_tokens)
        # 用 ASCII 兼容正则 (板上无 regex 库, re 不支持 \p{L})
        self.pat = re.compile(
            special + r"""|'s|'t|'re|'ve|'m|'ll|'d|[A-Za-z]+|[0-9]+|[^\sA-Za-z0-9]+""")

    def bpe(self, token):
        if token in self.cache:
            return self.cache[token]
        word = tuple(token[:-1]) + (token[-1] + '</w>',)
        pairs = get_pairs(word)
        if not pairs:
            return token + '</w>'

        while True:
            bigram = min(pairs, key=lambda p: self.bpe_ranks.get(p, float('inf')))
            if bigram not in self.bpe_ranks:
                break
            first, second = bigram
            new_word = []
            i = 0
            while i < len(word):
                try:
                    j = word.index(first, i)
                    new_word.extend(word[i:j])
                    i = j
                except Exception:
                    new_word.extend(word[i:])
                    break
                if word[i] == first and i < len(word)-1 and word[i+1] == second:
                    new_word.append(first + second)
                    i += 2
                else:
                    new_word.append(word[i])
                    i += 1
            word = tuple(new_word)
            if len(word) == 1:
                break
            pairs = get_pairs(word)
        word = ' '.join(word)
        self.cache[token] = word
        return word

    def encode(self, text):
        bpe_tokens = []
        text = text.lower().strip()
        for token in re.findall(self.pat, text):
            token = ''.join(self.byte_encoder[b] for b in token.encode('utf-8'))
            bpe_tokens.extend(self.encoder[bpe_token] for bpe_token in self.bpe(token).split(' '))
        return bpe_tokens

    def tokenize(self, text: str):
        tokens = [SOT] + self.encode(text) + [EOT]
        if len(tokens) > MAX_LEN:
            tokens = tokens[:MAX_LEN]
            tokens[-1] = EOT
        result = np.zeros(MAX_LEN, dtype=np.int32)
        result[:len(tokens)] = tokens
        return result

def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <labels.txt> <output_dir>", file=sys.stderr)
        sys.exit(1)
    labels_file, output_dir = sys.argv[1], sys.argv[2]
    os.makedirs(output_dir, exist_ok=True)

    # 查找 BPE vocab
    bpe_paths = [Path(output_dir) / "bpe_simple_vocab_16e6.txt.gz"]
    bpe_path = None
    for p in bpe_paths:
        if p.exists(): bpe_path = str(p); break
    if not bpe_path:
        print(f"ERROR: bpe_simple_vocab_16e6.txt.gz not found", file=sys.stderr)
        sys.exit(1)

    print(f"Loading BPE from {bpe_path}...")
    tok = SimpleTokenizer(bpe_path)
    print(f"Vocab size: {len(tok.encoder)}")

    with open(labels_file) as f:
        prompts = [line.strip() for line in f if line.strip()]

    for prompt in prompts:
        ids = tok.tokenize(prompt)
        out_path = os.path.join(output_dir, f"input_ids_{prompt}.bin")
        ids.tofile(out_path)
        print(f"  '{prompt}' -> {out_path} ids: {list(ids[:8])}")

    print(f"\nDone. {len(prompts)} files in {output_dir}")

if __name__ == "__main__":
    main()
