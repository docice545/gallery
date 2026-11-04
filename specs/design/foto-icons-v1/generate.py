"""Generate the review artifact and Flutter proposal from one original path manifest."""

import html
import json
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
manifest = json.loads((HERE / "manifest.json").read_text())
icons = manifest["icons"]
states = [
    ("default", "Обычное"),
    ("active", "Нажато / выбрано"),
    ("disabled", "Неактивно"),
    ("destructive", "Опасное действие"),
]
themes = {
    "light": dict(
        bg="#f6f7fb",
        panel="#ffffff",
        default="#253047",
        active="#4150af",
        disabled="#9297a3",
        destructive="#b3261e",
        tint="#e9ecfb",
    ),
    "dark": dict(
        bg="#101722",
        panel="#202b3c",
        default="#edf2fa",
        active="#accbfa",
        disabled="#747f91",
        destructive="#ffb4ab",
        tint="#324662",
    ),
}


def glyph(item, size, state, theme):
    color = themes[theme][state]
    stroke = manifest["strokeDp"][str(size)] * 24 / size
    paths = "".join(f'<path d="{html.escape(path)}"/>' for path in item["paths"])
    return f'<svg width="{size}" height="{size}" viewBox="0 0 24 24" fill="none" stroke="{color}" stroke-width="{stroke:.5f}" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">{paths}</svg>'


def matrix(item, theme):
    return (
        '<div class="matrix '
        + theme
        + '">'
        + "".join(
            '<div class="state '
            + state
            + '">'
            + "".join(
                '<span class="sample">' + glyph(item, size, state, theme) + "</span>"
                for size in [20, 22, 24]
            )
            + "</div>"
            for state, _ in states
        )
        + "</div>"
    )


rows = []
for icon in icons:
    rows.append(
        '<article data-group="'
        + icon["group"]
        + '"><div class="label"><b>'
        + html.escape(icon["label"])
        + "</b><code>"
        + icon["id"]
        + "</code><small>"
        + html.escape(icon["binding"])
        + "</small></div>"
        + matrix(icon, "light")
        + matrix(icon, "dark")
        + "</article>"
    )
header = (
    '<div class="legend"><div>Действие → существующая логика</div>'
    + "".join(
        '<div class="matrix '
        + theme
        + '">'
        + "".join(
            '<div class="state"><b>' + label + "</b><span>20 · 22 · 24 dp</span></div>"
            for _, label in states
        )
        + "</div>"
        for theme in themes
    )
    + "</div>"
)
css = """*{box-sizing:border-box}body{margin:0;background:#eef0f5;color:#253047;font:13px system-ui,Arial}header{padding:24px 30px;background:#fff;border-bottom:1px solid #dfe4ef}h1{margin:0 0 8px;font-size:28px;letter-spacing:-1px}header p{margin:5px 0;max-width:1100px}.pending{color:#8a4e00;font-weight:700}nav{padding:14px 30px;display:flex;gap:10px;align-items:center}button{border:1px solid #bdc6dc;background:white;color:#253047;border-radius:12px;min-height:48px;padding:0 20px;cursor:pointer}button[aria-pressed=true]{background:#4150af;color:white}main{padding:0 24px 24px;min-width:1212px}.legend,article{display:grid;grid-template-columns:244px 460px 460px;gap:8px;margin-bottom:5px}.legend{font-size:11px;margin-bottom:8px}.legend>div:first-child{padding:12px}.matrix{display:grid;grid-template-columns:repeat(4,1fr);gap:3px;border-radius:12px;padding:4px}.light{background:rgba(255,255,255,.92)}.dark{background:rgba(32,43,60,.94);color:#edf2fa}.state{display:flex;align-items:center;justify-content:space-evenly;min-height:60px;border-radius:9px}.legend .state{display:flex;flex-direction:column;min-height:42px;text-align:center}.sample{display:inline-flex;width:35px;height:48px;align-items:center;justify-content:center}.active{background:#e9ecfb}.dark .active{background:#324662}.label{display:flex;justify-content:center;flex-direction:column;padding:8px 12px;background:#fff;border-radius:12px}.label b{font-size:13px}.label code{font-size:10px;color:#586079}.label small{font-size:9px;color:#586079;margin-top:2px}.toolbar-demo{display:flex;gap:16px;margin:16px 0}.toolbar{display:flex;padding:6px;border-radius:22px;gap:6px}.toolbar .sample{height:48px;width:48px;border:1px dashed #8491aa44;border-radius:16px}.swatches{display:flex;gap:12px;align-items:center}.swatch{width:16px;height:16px;display:inline-block;border-radius:5px}footer{padding:20px 30px;color:#586079}.filtered{display:none}body[data-sheet=Viewer] article[data-group=Editor],body[data-sheet=Editor] article[data-group=Viewer]{display:none}@media print{nav{display:none}header{break-after:avoid}article{break-inside:avoid}body{background:#fff}}"""
lookup = {x["id"]: x for x in icons}
demo = (
    '<div class="toolbar-demo">'
    + "".join(
        '<div class="toolbar '
        + theme
        + '">'
        + "".join(
            '<span class="sample">'
            + glyph(
                lookup[id],
                22,
                (
                    "destructive"
                    if id == "trash"
                    else "active" if id == "favorite" else "default"
                ),
                theme,
            )
            + "</span>"
            for id in ["back", "share", "favorite", "edit", "trash"]
        )
        + "</div>"
        for theme in themes
    )
    + "</div>"
)
page = (
    '<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>FOTO · original icon proposal v1</title><style>'
    + css
    + '</style><body><header><h1>FOTO / иконки v1</h1><p class="pending">APPROVED BY USER · ccdb8a892 · согласованный вариант</p><p>Оригинальная геометрия на сетке 24: округлённые концы и соединения, спокойные открытые штрихи, оптическая толщина 1.65 / 1.75 / 1.85 dp. Цвета бренда — существующие #4150AF / #ACCBFA.</p><p>Каждая строка: все три реальных размера в каждом состоянии, на светлой и тёмной полупрозрачной панели. Масштаб браузера 100%: 1 CSS px = 1 логический dp; это не замер Samsung.</p>'
    + demo
    + '<p>Пунктир в примере показывает 48 × 48 dp зоны нажатия. Подписи присутствуют только в этом листе; кандидат компонента сохраняет tooltip и семантическое имя действия.</p></header><nav><button aria-pressed="true" onclick="filter(\'all\',this)">Все '
    + str(len(icons))
    + '</button><button aria-pressed="false" onclick="filter(\'Viewer\',this)">Viewer</button><button aria-pressed="false" onclick="filter(\'Editor\',this)">Редактор</button><span>Слева — светлая тема · справа — тёмная</span></nav><main>'
    + header
    + "".join(rows)
    + '</main><footer>Набор нарисован в исходных SVG-path вручную, без импортов и трассировки Samsung. Производственные панели и обработчики действий не заменены. Окончательная интеграция после утверждения.</footer><script>function filter(group,button){document.body.dataset.sheet=group;document.querySelectorAll("nav button").forEach(b=>b.setAttribute("aria-pressed",String(b===button)))}const sheet=new URLSearchParams(location.search).get("sheet");if(sheet)document.body.dataset.sheet=sheet;</script></body></html>'
)
(HERE / "preview.html").write_text(page)
lines = [
    "// Generated from specs/design/foto-icons-v1/manifest.json. Geometry approved by user at ccdb8a892.",
    "enum FotoIconKind { " + ", ".join(x["id"] for x in icons) + " }",
    "",
    "const fotoIconPaths = <FotoIconKind, String>{",
]
for item in icons:
    paths = "".join('<path d="' + path + '"/>' for path in item["paths"])
    lines.append("  FotoIconKind." + item["id"] + ": " + json.dumps(paths) + ",")
lines.append("};\n")
(
    ROOT / "mobile/lib/presentation/widgets/icons/proposal/foto_icon_paths.dart"
).write_text("\n".join(lines))
(HERE / "action-mapping.md").write_text(
    "# Icon-to-action mapping — approved by user at ccdb8a892\n\nLabels below are review labels, not new permanent captions in FOTO.\n\n| ID | Meaning | Existing action |\n| --- | --- | --- |\n"
    + "".join(f"| `{i['id']}` | {i['label']} | {i['binding']} |\n" for i in icons)
)
print("Generated preview, action mapping and", len(icons), "Flutter paths")

# Standalone vector sheets: renderable without browser file/network permissions.
for group in ["Viewer", "Editor"]:
    entries = [icon for icon in icons if icon["group"] == group]
    height = 180 + len(entries) * 66
    svg = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="1220" height="{height}" viewBox="0 0 1220 {height}">',
        '<rect width="100%" height="100%" fill="#eef0f5"/>',
    ]

    def text(x, y, value, size=12, color="#253047", weight="400"):
        return f'<text x="{x}" y="{y}" font-family="DejaVu Sans, sans-serif" font-size="{size}" font-weight="{weight}" fill="{color}">{html.escape(value)}</text>'

    svg.extend(
        [
            text(24, 40, "FOTO / " + group + " / original icons v1", 28, weight="700"),
            text(24, 65, "APPROVED BY USER · ccdb8a892", 12, "#8a4e00", "700"),
            text(
                24,
                88,
                "20 / 22 / 24 dp · original paths · rounded caps · brand #4150AF / #ACCBFA",
                12,
            ),
        ]
    )
    for ti, theme in enumerate(themes):
        start = 250 + ti * 474
        svg.append(
            text(
                start,
                113,
                (
                    "Светлая панель"
                    if theme == "light"
                    else "Тёмная полупрозрачная панель"
                ),
                12,
            )
        )
        for si, (_, label) in enumerate(states):
            svg.append(text(start + si * 116, 137, label, 9))
            svg.append(text(start + si * 116 + 10, 151, "20     22     24", 9))
    for ri, item in enumerate(entries):
        y = 162 + ri * 66
        svg.extend(
            [
                f'<rect x="16" y="{y}" width="222" height="61" rx="10" fill="white"/>',
                text(25, y + 23, item["label"], 11, weight="700"),
                text(25, y + 42, item["id"], 10, "#586079"),
            ]
        )
        for ti, theme in enumerate(themes):
            start = 250 + ti * 474
            svg.append(
                f'<rect x="{start-5}" y="{y}" width="466" height="61" rx="10" fill="{themes[theme]["panel"]}"/>'
            )
            for si, (state, _) in enumerate(states):
                x = start + si * 116
                if state == "active":
                    svg.append(
                        f'<rect x="{x-1}" y="{y+4}" width="110" height="53" rx="8" fill="{themes[theme]["tint"]}"/>'
                    )
                for zi, size in enumerate([20, 22, 24]):
                    svg.append(
                        f'<g transform="translate({x+zi*36+6} {y+(61-size)/2})">'
                        + glyph(item, size, state, theme)
                        + "</g>"
                    )
    svg.extend(
        [
            text(
                24,
                height - 6,
                "Review labels only · production controls retain 48 dp targets and semantic labels",
                10,
            ),
            " </svg>",
        ]
    )
    (HERE / (group.lower() + ".svg")).write_text("\n".join(svg))

# Compact overview; the two full sheets above remain the size/state reference.
width = 1120
height = 100 + math.ceil(len(icons) / 7) * 84
svg = [
    f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}">',
    '<rect width="100%" height="100%" fill="#eef0f5"/>',
    text(20, 34, "FOTO / " + str(len(icons)) + " original icons / review v1", 24),
    text(
        20,
        60,
        "APPROVED BY USER · ccdb8a892 · full 20/22/24 dp state sheets attached separately",
        12,
        "#8a4e00",
    ),
]
for index, item in enumerate(icons):
    x = 12 + (index % 7) * 158
    y = 80 + (index // 7) * 84
    svg.extend(
        [
            f'<rect x="{x}" y="{y}" width="150" height="76" rx="10" fill="white"/>',
            f'<rect x="{x+77}" y="{y+5}" width="64" height="40" rx="8" fill="#202b3c"/>',
        ]
    )
    for dx, theme in [(22, "light"), (98, "dark")]:
        svg.append(
            f'<g transform="translate({x+dx} {y+13})">'
            + glyph(item, 24, "default", theme)
            + "</g>"
        )
    svg.append(text(x + 8, y + 63, item["label"], 9))
svg.append("</svg>")
(HERE / "overview.svg").write_text("\n".join(svg))
