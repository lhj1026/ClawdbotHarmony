#!/usr/bin/env python3
"""Re-process talk mode icons - extract exact circle"""
from PIL import Image
import os
import math

media_dir = r'C:\Users\Liuho\ClawdBotHarmony\entry\src\main\resources\base\media'
source = os.path.join(media_dir, 'talkmode.jpg')

img = Image.open(source).convert('RGB')
width, height = img.size
print(f"Source size: {width}x{height}")

# Split in half
mid = width // 2

def find_circle_and_extract(img, output_path, target_size=144):
    """Find the colored circle (green or red) and extract it precisely"""
    pixels = img.load()
    w, h = img.size
    
    # Find the center and radius of the colored circle
    # Look for non-gray pixels (the green or red circle)
    colored_pixels = []
    for y in range(h):
        for x in range(w):
            r, g, b = pixels[x, y]
            # Check if it's a colored pixel (not white/gray background)
            # Green: high G, low R
            # Red: high R, low G
            is_green = g > 150 and g > r + 30
            is_red = r > 150 and r > g + 30
            if is_green or is_red:
                colored_pixels.append((x, y))
    
    if not colored_pixels:
        print(f"No colored circle found!")
        return
    
    # Find bounding box
    min_x = min(p[0] for p in colored_pixels)
    max_x = max(p[0] for p in colored_pixels)
    min_y = min(p[1] for p in colored_pixels)
    max_y = max(p[1] for p in colored_pixels)
    
    # Calculate center and radius
    center_x = (min_x + max_x) // 2
    center_y = (min_y + max_y) // 2
    radius = max(max_x - min_x, max_y - min_y) // 2 + 2  # Add small margin
    
    # Crop square around the circle
    left = center_x - radius
    top = center_y - radius
    right = center_x + radius
    bottom = center_y + radius
    
    # Ensure bounds
    left = max(0, left)
    top = max(0, top)
    right = min(w, right)
    bottom = min(h, bottom)
    
    # Make it square
    crop_w = right - left
    crop_h = bottom - top
    size = max(crop_w, crop_h)
    
    # Recenter
    left = center_x - size // 2
    top = center_y - size // 2
    right = left + size
    bottom = top + size
    
    # Final bounds check
    if left < 0:
        right -= left
        left = 0
    if top < 0:
        bottom -= top
        top = 0
    if right > w:
        left -= (right - w)
        right = w
    if bottom > h:
        top -= (bottom - h)
        bottom = h
    
    cropped = img.crop((left, top, right, bottom))
    resized = cropped.resize((target_size, target_size), Image.LANCZOS)
    resized.save(output_path, 'PNG')
    print(f"Saved {output_path} ({target_size}x{target_size}), circle at ({center_x},{center_y}) r={radius}")

# Process left half (green - talk mode)
left_img = img.crop((0, 0, mid, height))
find_circle_and_extract(left_img, os.path.join(media_dir, 'ic_talk_mode.png'), 144)

# Process right half (red - hangup)
right_img = img.crop((mid, 0, width, height))
find_circle_and_extract(right_img, os.path.join(media_dir, 'ic_hangup.png'), 144)

print("Done!")
