extends Node
## Автозагрузка Const — игровые константы, перенесённые из HTML-версии.

# Внутреннее разрешение 320x240 (рисуем в CanvasItem c scale = 3)
const BASE_W := 320
const BASE_H := 240
const KING_BOX_H := 28          # высота зала короля
const W := BASE_W               # ширина арены
const H := BASE_H - KING_BOX_H  # высота арены (212)
const SCALE := 3

const PLAYER_R := 5.0
const PLAYER_SPEED := 83.0
const SWORD_HIT_R := 3.5
const SWORD_LEN := 16.0
const SWORD_BASE_SPEED := 110.0
const SWORD_MAX_SPEED := 260.0
const SWORD_SPEEDUP := 1.025
const MAX_PLAYERS := 5
const RESPAWN_DELAY := 3.5
const TICK := 1.0 / 60.0
const SEND_INTERVAL := 1.0 / 30.0
const FX_DURATION := 1.9
const START_LIVES := 3
const HIT_INVULN := 2.0
