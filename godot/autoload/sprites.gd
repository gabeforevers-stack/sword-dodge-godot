extends Node
## Autoload "Sprites" — пиксельные спрайты, генерируемые из строк (как в HTML-версии).

const KNIGHT_SPRITE := [
	"...GGGG...",
	"..GWWWWG..",
	"..GWWWWG..",
	"..WKKKKW..",
	"...WWWW...",
	"..RRRRRR..",
	".RRRRRRRR.",
	"RRRRRRRRRR",
	".RRRRRRRR.",
	"..RR..RR..",
	"..RR..RR..",
	"..OO..OO..",
]

const KING_SPRITE := [
	"......G.G.G....",
	"......GGGGG....",
	".....GGGGGGG...",
	"......SSSSS....",
	".....SSSSSSS...",
	".....SSSSSSS...",
	"......SSSSS....",
	".....BBBBBBB...",
	".....BBBBBBB...",
	"....PPPPPPPPP..",
	"...PPPPPPPPPPP.",
	"..PPPPPPPPPPPPP",
	"..PPPPPPPPPPPPP",
	".PPPPPPPPPPPPPP",
	"PPPPPPPPPPPPPPP",
	"PPPPPPPPPPPPPPP",
	"PP.GGGGGGGGG.PP",
	"PPPPPPPPPPPPPPP",
]

const HEART_SPRITE := [
	"H.H",
	"HHH",
	".H.",
]

const KING_PALETTE := {
	"G": Color("#f0c040"),
	"S": Color("#e8b890"),
	"B": Color("#d0d0d0"),
	"P": Color("#7a2870"),
}

const COLORS := [
	Color("#e04040"), Color("#4080e0"), Color("#40c060"),
	Color("#f0c040"), Color("#a060e0"),
]

var _knight_cache := {}


func knight_palette(color: Color) -> Dictionary:
	return {
		"G": Color("#f0c040"),
		"W": Color("#c0c8d8"),
		"K": Color("#0a0c14"),
		"R": color,
		"O": Color("#6a4020"),
	}


func ghost_palette() -> Dictionary:
	return {
		"G": Color("#707070"), "W": Color("#808080"), "K": Color("#202020"),
		"R": Color("#606060"), "O": Color("#4a4038"),
	}


## Возвращает Texture2D рыцаря заданного цвета (с кэшированием).
func knight_texture(color: Color) -> Texture2D:
	var key := color.to_html(false)
	if not _knight_cache.has(key):
		_knight_cache[key] = make_texture(KNIGHT_SPRITE, knight_palette(color))
	return _knight_cache[key]


func make_texture(sprite: Array, palette: Dictionary) -> ImageTexture:
	var h := sprite.size()
	var w := 0
	for row in sprite:
		w = max(w, row.length())
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in h:
		var line: String = sprite[y]
		for x in line.length():
			var ch := line[x]
			if ch == ".":
				continue
			if palette.has(ch):
				img.set_pixel(x, y, palette[ch])
	return ImageTexture.create_from_image(img)
