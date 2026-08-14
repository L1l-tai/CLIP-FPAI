"""Generate reference input_ids with official CLIP library for comparison."""
import sys, os, numpy as np

try:
    import clip
except ImportError:
    print("pip install git+https://github.com/openai/CLIP.git")
    sys.exit(1)

def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <labels.txt> <output_dir>")
        sys.exit(1)

    labels_file = sys.argv[1]
    output_dir = sys.argv[2]
    os.makedirs(output_dir, exist_ok=True)

    with open(labels_file) as f:
        prompts = [line.strip() for line in f if line.strip()]

    print("Loading CLIP ViT-B/32 tokenizer...")
    model, _ = clip.load("ViT-B/32", device="cpu")

    for prompt in prompts:
        ids = clip.tokenize([prompt])[0].numpy().astype(np.int32)
        out_path = os.path.join(output_dir, f"ref_input_ids_{prompt}.bin")
        ids.tofile(out_path)
        print(f"  {prompt}: {list(ids[:10])}... ({len(ids)} tokens) -> {out_path}")

    print(f"\nDone. {len(prompts)} files in {output_dir}")
    print("Compare with: diff <(xxd ref_input_ids_bear.bin) <(xxd board_data/input_ids_bear.bin)")

if __name__ == "__main__":
    main()
