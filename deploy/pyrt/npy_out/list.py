import numpy as np
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent

items = [
    ("bear", "text_bear.npy"),
    ("cat", "text_cat.npy"),
    ("dog", "text_dog.npy"),
    ("drone", "text_drone.npy"),
    ("ambulance", "text_ambulance.npy"),
]

labels = []
features = []

for label, filename in items:
    path = BASE_DIR / filename
    print("loading:", path)

    feat = np.load(path).astype(np.float32).reshape(-1)
    assert feat.shape[0] == 512, (label, feat.shape)

    feat = feat / np.linalg.norm(feat)

    labels.append(label)
    features.append(feat)

features = np.stack(features, axis=0).astype(np.float32)

labels_path = BASE_DIR / "clip_labels.txt"
features_path = BASE_DIR / "clip_text_features.bin"

with open(labels_path, "w", encoding="utf-8") as f:
    for label in labels:
        f.write(label + "\n")

features.tofile(features_path)

print("features shape:", features.shape)
print("saved:", labels_path)
print("saved:", features_path)