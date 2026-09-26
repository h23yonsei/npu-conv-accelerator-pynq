"""End-to-end golden-model validation against the data in data/.

Pipeline (stride 1, no padding):
  Conv1(8,1,3,3)  -> LeakyReLU -> Fmap1(8,26,26)
  Conv2(16,8,3,3) -> LeakyReLU -> Fmap2(16,24,24)
  Conv3(64,16,3,3)-> LeakyReLU -> Fmap3(64,22,22)
  Conv4(128,64,3,3)->LeakyReLU -> Fmap4(128,20,20)
  MaxPool(2x2)             -> Fmap5(128,10,10)
  FC(12800,10)             -> Output(10)
"""

import os

import numpy as np

from conv2d import conv2d_9for, leaky_relu, maxpool2d, fc_layer

DATA_DIR = os.path.join(os.path.dirname(__file__), "..", "data")


def load(name):
    return np.load(os.path.join(DATA_DIR, name))


def load_weights():
    return {
        "conv": [load(f"layer{i}_0_weight.npy") for i in range(1, 5)],
        "fc": load("fc1_weight.npy"),
    }


def forward(image, weights):
    x = image.astype(np.int32)
    for w in weights["conv"]:
        x = conv2d_9for(x, w)
        x = leaky_relu(x)
    x = maxpool2d(x)
    return fc_layer(x, weights["fc"])


def main(num_images=20):
    input_data = load("input.npy")
    labels = load("label.npy")
    output_ref = load("output.npy")
    weights = load_weights()

    correct = 0
    ref_agree = 0
    for i in range(num_images):
        logits = forward(input_data[i], weights)
        pred = int(np.argmax(logits))
        ref_pred = int(np.argmax(output_ref[i]))
        label = int(labels[i])

        correct += pred == label
        ref_agree += pred == ref_pred
        print(f"image {i:3d}: golden_pred={pred} ref_pred={ref_pred} label={label} logits={logits}")

    print(f"\naccuracy vs label.npy:  {correct}/{num_images}")
    print(f"agreement vs output.npy argmax: {ref_agree}/{num_images}")


if __name__ == "__main__":
    main()
