# Importality

[![en](https://img.shields.io/badge/lang-en-red.svg)](README.md)
[![ru](https://img.shields.io/badge/lang-ru-green.svg)](README.ru.md)

**Importality — дополнение для Godot для импорта графики и анимации из внешних графических редакторов.**

Этот fork сохраняет архитектуру upstream Importality и добавляет полноценную поддержку промежуточного формата **Krita Layers** (`.kritalayers`). Цель — разделить авторинг, импорт и runtime-потребителя.

```text
Krita / другой редактор
        ↓
   .kritalayers
        ↓
   Importality
        ↓
 ресурс Godot
        ├── B42
        ├── Dialogic 2
        └── любой другой runtime
```

## Krita Layers v2

`.kritalayers` — ZIP-формат с `manifest.json`, PNG-кадрами, SHA-256 и дополнительными metadata. Текущая авторская конвенция:

```text
@export
├── BODY
│   └── *base
├── FACE
│   ├── *neutral
│   └── smile
└── +DETAILS
    ├── *none
    └── cut_face
```

`*` означает default, `+` — additive slot.

Если `.kra` содержит annotation из [Krita Sprite Visibility Rules](https://github.com/EvelynLimaB/krita-sprite-visibility-rules), правила экспортируются в metadata и становятся доступны импортированному ресурсу. Importality не зависит от самого plugin-а правил.

## Установка

### Godot

Скопируйте содержимое `addons/` в `addons/` проекта и включите **Importality** в `Project Settings → Plugins`.

### Krita

Установите содержимое:

```text
tools/krita_plugin/
```

как Python plugin Krita. После перезапуска появится:

```text
Tools → Scripts → Importality: Export .kritalayers
```

Если `.kra` находится внутри Godot-проекта, по умолчанию bundle создаётся в:

```text
assets/importality/<source-name>.kritalayers
```

## Использование в Godot

`.kritalayers` импортируется обычным pipeline Importality. Например:

```gdscript
var frames: SpriteFrames = load("res://assets/importality/belle.kritalayers")
```

Importality не знает, что такое персонаж или portrait. Это ответственность потребляющей системы.

## B42 и Dialogic 2

`B42LayeredPortrait` — один из потребителей этого расширения. Dialogic 2 может передавать ему semantic state/extra data. При этом Importality не зависит от B42 и Dialogic.

## Архитектура и развитие

Текущий exporter использует явную `@export`-структуру и создаёт один логический bundle на исходный документ. Архитектура рассчитана на дальнейшее добавление export definitions, чтобы один `.kra` мог удобно описывать несколько asset-ов и произвольные структуры без привязки к portrait workflow.

Upstream:
https://github.com/nklbdev/godot-4-importality

Fork:
https://github.com/eveorgr/godot-4-importality
