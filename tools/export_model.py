#!/usr/bin/env python3
"""
Export a HuggingFace sentence-transformers model to binary format
for on-device inference in ClawdbotHarmony.

Usage:
    pip install torch transformers sentencepiece
    python tools/export_model.py [--model MODEL_NAME] [--output OUTPUT_DIR]

Default model: sentence-transformers/all-MiniLM-L6-v2
Default output: entry/src/main/resources/rawfile/model/
"""

import argparse
import json
import os
import struct
import numpy as np

MAGIC = 0x454D4231  # "EMB1"


def export_bin(tensors: dict, output_path: str):
    """
    Export tensors to binary file with header.
    Format:
      magic(4B) + tensor_count(4B)
      For each tensor:
        name_len(4B) + name(UTF-8) + ndim(4B) + shape(4B * ndim) + data_len(4B)
      Then concatenated float16 data for all tensors
    """
    header = bytearray()
    data = bytearray()

    header += struct.pack('<I', MAGIC)
    header += struct.pack('<I', len(tensors))

    for name, arr in tensors.items():
        arr_f16 = arr.astype(np.float16)
        name_bytes = name.encode('utf-8')
        header += struct.pack('<I', len(name_bytes))
        header += name_bytes
        header += struct.pack('<I', len(arr_f16.shape))
        for dim in arr_f16.shape:
            header += struct.pack('<I', dim)
        raw = arr_f16.tobytes()
        header += struct.pack('<I', len(raw))
        data += raw

    with open(output_path, 'wb') as f:
        f.write(header)
        f.write(data)

    size_mb = (len(header) + len(data)) / (1024 * 1024)
    print(f"  -> {output_path} ({size_mb:.1f} MB, {len(tensors)} tensors)")


def main():
    parser = argparse.ArgumentParser(description='Export embedding model for on-device inference')
    parser.add_argument('--model', default='sentence-transformers/all-MiniLM-L6-v2',
                        help='HuggingFace model name')
    parser.add_argument('--output', default=None,
                        help='Output directory (default: entry/src/main/resources/rawfile/model/)')
    args = parser.parse_args()

    # Determine output directory
    if args.output:
        out_dir = args.output
    else:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        project_root = os.path.dirname(script_dir)
        out_dir = os.path.join(project_root, 'entry', 'src', 'main', 'resources', 'rawfile', 'model')

    os.makedirs(out_dir, exist_ok=True)
    print(f"Exporting model: {args.model}")
    print(f"Output directory: {out_dir}")

    # Import here to allow --help without torch
    from transformers import AutoModel, AutoTokenizer

    print("Loading model and tokenizer...")
    tokenizer = AutoTokenizer.from_pretrained(args.model)
    model = AutoModel.from_pretrained(args.model)
    model.eval()

    config = model.config
    print(f"  hidden_size={config.hidden_size}, num_layers={config.num_hidden_layers}, "
          f"num_heads={config.num_attention_heads}, intermediate={config.intermediate_size}, "
          f"vocab_size={config.vocab_size}")

    # ---- 1. Export config.json ----
    model_config = {
        'hidden_size': config.hidden_size,
        'num_hidden_layers': config.num_hidden_layers,
        'num_attention_heads': config.num_attention_heads,
        'intermediate_size': config.intermediate_size,
        'max_position_embeddings': config.max_position_embeddings,
        'vocab_size': config.vocab_size,
        'embedding_dim': config.hidden_size,  # output dimension = hidden for MiniLM
        'model_name': args.model.split('/')[-1],
    }
    config_path = os.path.join(out_dir, 'config.json')
    with open(config_path, 'w') as f:
        json.dump(model_config, f, indent=2)
    print(f"  -> {config_path}")

    # ---- 2. Export vocab.json ----
    vocab = tokenizer.get_vocab()
    vocab_path = os.path.join(out_dir, 'vocab.json')
    with open(vocab_path, 'w', encoding='utf-8') as f:
        json.dump(vocab, f, ensure_ascii=False)
    print(f"  -> {vocab_path} ({len(vocab)} tokens)")

    # ---- 3. Export tokenizer.json ----
    tok_config = {
        'cls_token': tokenizer.cls_token,
        'sep_token': tokenizer.sep_token,
        'pad_token': tokenizer.pad_token,
        'unk_token': tokenizer.unk_token,
        'cls_token_id': tokenizer.cls_token_id,
        'sep_token_id': tokenizer.sep_token_id,
        'pad_token_id': tokenizer.pad_token_id,
        'unk_token_id': tokenizer.unk_token_id,
        'max_length': 128,
        'do_lower_case': True,
    }
    tok_path = os.path.join(out_dir, 'tokenizer.json')
    with open(tok_path, 'w') as f:
        json.dump(tok_config, f, indent=2)
    print(f"  -> {tok_path}")

    # ---- 4. Export embeddings.bin ----
    sd = model.state_dict()
    emb_tensors = {}
    prefix = 'embeddings.'
    for key in sd:
        if key.startswith(prefix):
            short = key[len(prefix):]
            emb_tensors[short] = sd[key].cpu().numpy()

    export_bin(emb_tensors, os.path.join(out_dir, 'embeddings.bin'))

    # ---- 5. Export layer weights ----
    for layer_idx in range(config.num_hidden_layers):
        layer_prefix = f'encoder.layer.{layer_idx}.'
        layer_tensors = {}
        for key in sd:
            if key.startswith(layer_prefix):
                short = key[len(layer_prefix):]
                layer_tensors[short] = sd[key].cpu().numpy()

        export_bin(layer_tensors, os.path.join(out_dir, f'layer_{layer_idx:02d}.bin'))

    # ---- 6. Export pooler.bin ----
    pooler_tensors = {}
    for key in sd:
        if key.startswith('pooler.'):
            short = key[len('pooler.'):]
            pooler_tensors[short] = sd[key].cpu().numpy()

    if pooler_tensors:
        export_bin(pooler_tensors, os.path.join(out_dir, 'pooler.bin'))
    else:
        print("  (no pooler weights found)")

    # ---- 7. Export test vectors for validation ----
    import torch
    test_texts = [
        "Hello world",
        "This is a test sentence for embedding.",
        "The quick brown fox jumps over the lazy dog.",
    ]
    print("\nGenerating test vectors for validation...")
    test_data = []
    for text in test_texts:
        encoded = tokenizer(text, padding='max_length', truncation=True,
                            max_length=128, return_tensors='pt')
        with torch.no_grad():
            output = model(**encoded)
        # Mean pooling
        token_embeddings = output.last_hidden_state
        attention_mask = encoded['attention_mask'].unsqueeze(-1).expand(token_embeddings.size()).float()
        sum_embeddings = torch.sum(token_embeddings * attention_mask, dim=1)
        sum_mask = torch.clamp(attention_mask.sum(dim=1), min=1e-9)
        mean_pooled = sum_embeddings / sum_mask
        # L2 normalize
        normalized = torch.nn.functional.normalize(mean_pooled, p=2, dim=1)
        vec = normalized[0].tolist()
        token_ids = encoded['input_ids'][0].tolist()
        test_data.append({
            'text': text,
            'token_ids': token_ids[:sum(encoded['attention_mask'][0].tolist())],  # only non-pad
            'embedding': vec,
        })
        print(f"  '{text}' -> dim={len(vec)}, tokens={len(test_data[-1]['token_ids'])}")

    test_path = os.path.join(out_dir, 'test_vectors.json')
    with open(test_path, 'w') as f:
        json.dump(test_data, f)
    print(f"  -> {test_path}")

    # Summary
    total_size = 0
    for fname in os.listdir(out_dir):
        fpath = os.path.join(out_dir, fname)
        total_size += os.path.getsize(fpath)
    print(f"\nTotal model size: {total_size / (1024 * 1024):.1f} MB")
    print("Export complete!")


if __name__ == '__main__':
    main()
