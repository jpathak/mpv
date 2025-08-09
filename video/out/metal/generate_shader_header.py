#!/usr/bin/env python3
"""
Generate a C header file from Metal shader source
"""

import sys
import os

def generate_header(input_file, output_file):
    with open(input_file, 'r') as f:
        shader_source = f.read()
    
    # Escape special characters
    shader_source = shader_source.replace('\\', '\\\\')
    shader_source = shader_source.replace('"', '\\"')
    shader_source = shader_source.replace('\n', '\\n"\n"')
    
    # Generate header content
    header_content = f'// Auto-generated from {os.path.basename(input_file)}\n'
    header_content += f'// Do not edit manually\n\n'
    header_content += f'"{shader_source}"\n'
    
    with open(output_file, 'w') as f:
        f.write(header_content)
    
    print(f"Generated {output_file} from {input_file}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: generate_shader_header.py <input.metal> <output.h>")
        sys.exit(1)
    
    generate_header(sys.argv[1], sys.argv[2])