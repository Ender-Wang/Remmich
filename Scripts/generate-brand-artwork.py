#!/usr/bin/env python3
"""Bake approved SVG paint layers for native animation; requires rsvg-convert.

Reads the committed Icon Composer SVGs. Separate shadow, multiply fill, and
reflection layers retain the source compositing without Apple's SVG filters.
"""

import copy
import json
import math
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
NS = "{http://www.w3.org/2000/svg}"
IDENTITY = [1, 0, 0, 1, 0, 0]


def multiply(a, b):
    return [a[0]*b[0]+a[2]*b[1], a[1]*b[0]+a[3]*b[1],
            a[0]*b[2]+a[2]*b[3], a[1]*b[2]+a[3]*b[3],
            a[0]*b[4]+a[2]*b[5]+a[4], a[1]*b[4]+a[3]*b[5]+a[5]]


def point(m, x, y):
    return [m[0]*x+m[2]*y+m[4], m[1]*x+m[3]*y+m[5]]


def inverse(m):
    a, b, c, d, x, y = m
    determinant = a*d-b*c
    return [d/determinant, -b/determinant, -c/determinant,
            a/determinant, (c*y-d*x)/determinant, (b*x-a*y)/determinant]


def transform(value):
    result = IDENTITY
    for name, arguments in re.findall(r"(\w+)\(([^)]+)\)", value):
        v = list(map(float, re.findall(r"[-+]?(?:\d*\.)?\d+(?:e[-+]?\d+)?", arguments)))
        if name == "matrix":
            m = v
        elif name == "translate":
            m = [1, 0, 0, 1, v[0], v[1] if len(v) > 1 else 0]
        elif name == "scale":
            m = [v[0], 0, 0, v[1] if len(v) > 1 else v[0], 0, 0]
        elif name == "rotate":
            angle = math.radians(v[0]); c, s = math.cos(angle), math.sin(angle)
            m = [c, s, -s, c, 0, 0]
            if len(v) == 3:
                m = multiply(multiply([1, 0, 0, 1, v[1], v[2]], m), [1, 0, 0, 1, -v[1], -v[2]])
        else:
            raise ValueError(f"Unsupported transform: {name}")
        result = multiply(result, m)
    return result


def main():
    scenes = {}
    for name in ("Spiral", "Spaced", "Mosaic"):
        source = ROOT / f"Remmich/Resources/AppIcons/AppIcon-{name}.icon/Assets/Remmich-{name}.svg"
        svg = ET.parse(source).getroot()
        definitions = next(n for n in svg if n.tag == NS + "defs")
        shapes = {n.attrib['id']: n for n in definitions if n.tag == NS + "rect"}
        parents = {child: parent for parent in svg.iter() for child in parent}
        tiles = []
        for tile in (n for n in svg.iter() if 'data-tile' in n.attrib):
            local = next(n for n in tile if n.tag == NS + "g")
            use = next(n for n in local if n.tag == NS + "use")
            shape = shapes[use.attrib['href'][1:]]
            width, height, radius = (float(shape.attrib[k]) for k in ('width', 'height', 'rx'))
            chain, node = [], local
            while node is not svg:
                chain.insert(0, node); node = parents[node]
            world = IDENTITY
            for node in chain:
                world = multiply(world, transform(node.attrib.get('transform', '')))
            root = IDENTITY
            for node in chain[:-2]:
                root = multiply(root, transform(node.attrib.get('transform', '')))
            center = point(inverse(world), *point(root, 512, 512))
            nearest = [min(width-radius, max(radius, center[0])), min(height-radius, max(radius, center[1]))]
            dx, dy = center[0]-nearest[0], center[1]-nearest[1]
            distance = math.hypot(dx, dy)
            if distance > radius:
                nearest = [nearest[0]+dx*radius/distance, nearest[1]+dy*radius/distance]
            else:
                nearest = center
            corners = [point(world, x, y) for x in (-32, width+32) for y in (-32, height+42)]
            x, y = math.floor(min(p[0] for p in corners)), math.floor(min(p[1] for p in corners))
            bounds = [x, y, math.ceil(max(p[0] for p in corners))-x, math.ceil(max(p[1] for p in corners))-y]
            layers = []
            for paint in ('under', 'fill', 'over'):
                children = [n for n in local if ('under' if 'filter' in n.attrib else 'fill' if n.tag == NS+'use' and n.attrib.get('fill') != 'none' else 'over') == paint]
                if not children:
                    continue
                image = f"Remmich{name}{tile.attrib['data-tile'].title()}{paint.title()}"
                target = ROOT / f"Remmich/Assets.xcassets/{image}.imageset"
                target.mkdir(parents=True, exist_ok=True)
                output = ET.Element(NS+'svg', width=str(bounds[2]), height=str(bounds[3]), viewBox=' '.join(map(str, bounds)))
                output.append(copy.deepcopy(definitions))
                group = ET.SubElement(output, NS+'g', transform='matrix('+ ' '.join(map(str, world))+')')
                group.extend(copy.deepcopy(children))
                with tempfile.TemporaryDirectory(prefix='remmich-art-') as temporary:
                    path = Path(temporary)/'layer.svg'; ET.ElementTree(output).write(path)
                    subprocess.run(['rsvg-convert', str(path), '-o', str(target/(image+'.png'))], check=True)
                (target/'Contents.json').write_text(json.dumps({'images':[{'filename':image+'.png','idiom':'universal'}], 'info':{'author':'xcode','version':1}}, indent=2)+'\n')
                layers.append({'image':image, 'multiply':paint == 'fill'})
            tiles.append({'id':tile.attrib['data-tile'], 'bounds':bounds, 'anchor':point(world,*nearest),
                          'width':width,'height':height,'center':point(transform(local.attrib.get('transform','')),width/2,height/2), 'layers':layers})
        scenes[name] = {'transform':root, 'tiles':tiles}
    target = ROOT/'Remmich/Resources/Brand/RemmichBrandArtwork.json'
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(scenes, separators=(',', ':'))+'\n')
    print(f"Generated {sum(len(t['layers']) for s in scenes.values() for t in s['tiles'])} native layers from the approved SVGs.")


if __name__ == '__main__':
    main()
