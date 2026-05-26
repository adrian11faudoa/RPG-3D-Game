## systems/weather/weather_system.gd
## Simulates weather transitions, day/night cycle, and environmental effects.
## Weather affects gameplay: rain reduces fire, snow slows movement, storms drain stamina.

class_name WeatherSystem
extends Node

# ─── Signals ──────────────────────────────────────────────────────────────────
signal weather_changed(old_weather: WeatherState, new_weather: WeatherState)
signal time_of_day_changed(hour: float)

# ─── Enums ────────────────────────────────────────────────────────────────────
enum WeatherState {
	CLEAR, CLOUDY, LIGHT_RAIN, HEAVY_RAIN,
	THUNDERSTORM, LIGHT_SNOW, BLIZZARD,
	FOG, HEATWAVE, SANDSTORM
}

# ─── Day/Night Constants ──────────────────────────────────────────────────────
const DAY_LENGTH_SECONDS : float = 1200.0  # 20 real minutes = 1 game day
const SUNRISE_HOUR       : float = 6.0
const SUNSET_HOUR        : float = 20.0
const HOURS_PER_DAY      : float = 24.0

# ─── Node References ──────────────────────────────────────────────────────────
@onready var _sun          : DirectionalLight3D = $Sun
@onready var _moon         : DirectionalLight3D = $Moon
@onready var _sky          : WorldEnvironment   = $WorldEnvironment
@onready var _rain_particles: GPUParticles3D    = $RainParticles
@onready var _snow_particles: GPUParticles3D    = $SnowParticles
@onready var _lightning    : Node3D             = $LightningSystem
@onready var _wind_audio   : AudioStreamPlayer3D= $WindAudio
@onready var _rain_audio   : AudioStreamPlayer3D= $RainAudio

# ─── State ────────────────────────────────────────────────────────────────────
var _world_time      : float = 480.0   # Seconds into current day (8:00 AM start)
var _current_weather : WeatherState = WeatherState.CLEAR
var _target_weather  : WeatherState = WeatherState.CLEAR
var _transition_time : float = 0.0
var _transition_dur  : float = 60.0   # Seconds to transition between weather
var _weather_timer   : float = 300.0  # Seconds until next weather roll
var _current_biome   : String = "temperate_forest"

# Transition state (lerped values)
var _cloud_cover     : float = 0.0
var _rain_intensity  : float = 0.0
var _fog_density     : float = 0.005
var _wind_strength   : float = 0.0
var _lightning_chance: float = 0.0

# Sun/Moon cycle
var _sun_angle       : float = 0.0
var _ambient_energy  : float = 1.0
var _sun_energy      : float = 1.0


func _ready() -> void:
	_update_sun_position()
	_apply_weather_immediate(_current_weather)


func _process(delta: float) -> void:
	_tick_time(delta)
	_tick_weather_transition(delta)
	_tick_weather_timer(delta)
	_tick_lightning(delta)
	_update_sun_position()
	_apply_lerped_environment()


# ─── Time of Day ──────────────────────────────────────────────────────────────
func _tick_time(delta: float) -> void:
	_world_time += delta
	if _world_time >= DAY_LENGTH_SECONDS:
		_world_time -= DAY_LENGTH_SECONDS

	var prev_hour := get_hour()
	var new_hour  := get_hour()
	if floori(prev_hour) != floori(new_hour):
		time_of_day_changed.emit(new_hour)


func get_hour() -> float:
	return (_world_time / DAY_LENGTH_SECONDS) * HOURS_PER_DAY


func get_time_string() -> String:
	var hour   := int(get_hour())
	var minute := int((get_hour() - hour) * 60.0)
	return "%02d:%02d" % [hour, minute]


func is_daytime() -> bool:
	var hour := get_hour()
	return hour >= SUNRISE_HOUR and hour < SUNSET_HOUR


func get_light_intensity() -> float:
	var hour := get_hour()
	if hour < SUNRISE_HOUR - 1.0 or hour > SUNSET_HOUR + 1.0:
		return 0.05  # Night
	if hour < SUNRISE_HOUR:
		return lerpf(0.05, 1.0, (hour - (SUNRISE_HOUR - 1.0)))
	if hour > SUNSET_HOUR:
		return lerpf(1.0, 0.05, (hour - SUNSET_HOUR))
	# Soft dip at noon for stylized look
	if hour > 11.0 and hour < 13.0:
		return 0.95
	return 1.0


func _update_sun_position() -> void:
	var hour := get_hour()
	# Sun rotates 180° from sunrise to sunset
	var sun_t := (hour - SUNRISE_HOUR) / (SUNSET_HOUR - SUNRISE_HOUR)
	sun_t      = clampf(sun_t, 0.0, 1.0)
	_sun_angle = lerpf(-90.0, 90.0, sun_t) - 90.0

	_sun.rotation_degrees  = Vector3(_sun_angle, -30.0, 0.0)
	_moon.rotation_degrees = Vector3(_sun_angle + 180.0, -30.0, 0.0)

	var light := get_light_intensity() * (1.0 - _cloud_cover * 0.7)
	_sun.light_energy  = light * _sun_energy
	_moon.light_energy = (1.0 - light) * 0.15

	# Sun color temperature (warm morning/evening, white noon)
	var warmth := absf(sun_t - 0.5) * 2.0
	_sun.light_color = Color(
		1.0,
		lerpf(1.0, 0.75, warmth),
		lerpf(1.0, 0.5,  warmth)
	)


# ─── Weather Management ───────────────────────────────────────────────────────
func _tick_weather_timer(delta: float) -> void:
	_weather_timer -= delta
	if _weather_timer <= 0.0:
		_roll_weather()
		_weather_timer = randf_range(180.0, 600.0)  # 3-10 minutes between changes


func _roll_weather() -> void:
	var table := _get_weather_table(_current_biome)
	var roll  := randf()
	var accum := 0.0
	for entry: Dictionary in table:
		accum += float(entry["weight"])
		if roll <= accum:
			request_weather(entry["weather"] as WeatherState)
			return


func _get_weather_table(biome: String) -> Array:
	# Biome-specific weather probability tables
	match biome:
		"desert", "volcanic":
			return [
				{"weather": WeatherState.CLEAR,     "weight": 0.7},
				{"weather": WeatherState.CLOUDY,    "weight": 0.15},
				{"weather": WeatherState.HEATWAVE,  "weight": 0.1},
				{"weather": WeatherState.SANDSTORM, "weight": 0.05},
			]
		"tundra", "alpine":
			return [
				{"weather": WeatherState.CLEAR,       "weight": 0.3},
				{"weather": WeatherState.CLOUDY,      "weight": 0.2},
				{"weather": WeatherState.LIGHT_SNOW,  "weight": 0.3},
				{"weather": WeatherState.BLIZZARD,    "weight": 0.15},
				{"weather": WeatherState.FOG,         "weight": 0.05},
			]
		"swamp":
			return [
				{"weather": WeatherState.FOG,         "weight": 0.35},
				{"weather": WeatherState.LIGHT_RAIN,  "weight": 0.3},
				{"weather": WeatherState.HEAVY_RAIN,  "weight": 0.15},
				{"weather": WeatherState.CLOUDY,      "weight": 0.15},
				{"weather": WeatherState.CLEAR,       "weight": 0.05},
			]
		_:  # Default temperate
			return [
				{"weather": WeatherState.CLEAR,        "weight": 0.35},
				{"weather": WeatherState.CLOUDY,       "weight": 0.25},
				{"weather": WeatherState.LIGHT_RAIN,   "weight": 0.2},
				{"weather": WeatherState.HEAVY_RAIN,   "weight": 0.1},
				{"weather": WeatherState.THUNDERSTORM, "weight": 0.05},
				{"weather": WeatherState.FOG,          "weight": 0.05},
			]


func request_weather(new_weather: WeatherState) -> void:
	if new_weather == _current_weather:
		return
	_target_weather  = new_weather
	_transition_time = 0.0
	weather_changed.emit(_current_weather, new_weather)
	print("[Weather] Transitioning to: %s" % WeatherState.keys()[new_weather])


# ─── Transition ───────────────────────────────────────────────────────────────
func _tick_weather_transition(delta: float) -> void:
	if _current_weather == _target_weather:
		return
	_transition_time += delta
	var t := _transition_time / _transition_dur

	if t >= 1.0:
		_current_weather = _target_weather
		_apply_weather_immediate(_current_weather)
		return

	# Lerp between source and target weather parameters
	var src := _get_weather_params(_current_weather)
	var dst := _get_weather_params(_target_weather)
	_cloud_cover      = lerpf(src["cloud"], dst["cloud"], t)
	_rain_intensity   = lerpf(src["rain"],  dst["rain"],  t)
	_fog_density      = lerpf(src["fog"],   dst["fog"],   t)
	_wind_strength    = lerpf(src["wind"],  dst["wind"],  t)
	_lightning_chance = lerpf(src["lightning"], dst["lightning"], t)

	_update_particle_systems()
	_update_audio()


func _get_weather_params(weather: WeatherState) -> Dictionary:
	match weather:
		WeatherState.CLEAR:
			return {"cloud": 0.0,  "rain": 0.0, "fog": 0.003, "wind": 0.1,  "lightning": 0.0}
		WeatherState.CLOUDY:
			return {"cloud": 0.6,  "rain": 0.0, "fog": 0.006, "wind": 0.3,  "lightning": 0.0}
		WeatherState.LIGHT_RAIN:
			return {"cloud": 0.75, "rain": 0.3, "fog": 0.01,  "wind": 0.4,  "lightning": 0.0}
		WeatherState.HEAVY_RAIN:
			return {"cloud": 0.9,  "rain": 0.8, "fog": 0.02,  "wind": 0.7,  "lightning": 0.0}
		WeatherState.THUNDERSTORM:
			return {"cloud": 1.0,  "rain": 1.0, "fog": 0.025, "wind": 1.0,  "lightning": 0.8}
		WeatherState.LIGHT_SNOW:
			return {"cloud": 0.7,  "rain": 0.2, "fog": 0.012, "wind": 0.5,  "lightning": 0.0}
		WeatherState.BLIZZARD:
			return {"cloud": 1.0,  "rain": 1.0, "fog": 0.05,  "wind": 1.0,  "lightning": 0.0}
		WeatherState.FOG:
			return {"cloud": 0.5,  "rain": 0.0, "fog": 0.08,  "wind": 0.05, "lightning": 0.0}
		WeatherState.HEATWAVE:
			return {"cloud": 0.1,  "rain": 0.0, "fog": 0.002, "wind": 0.05, "lightning": 0.0}
		WeatherState.SANDSTORM:
			return {"cloud": 0.8,  "rain": 0.0, "fog": 0.04,  "wind": 1.0,  "lightning": 0.0}
		_:
			return {"cloud": 0.0,  "rain": 0.0, "fog": 0.003, "wind": 0.1,  "lightning": 0.0}


func _apply_weather_immediate(weather: WeatherState) -> void:
	var params := _get_weather_params(weather)
	_cloud_cover      = params["cloud"]
	_rain_intensity   = params["rain"]
	_fog_density      = params["fog"]
	_wind_strength    = params["wind"]
	_lightning_chance = params["lightning"]
	_update_particle_systems()
	_update_audio()


# ─── Environment Updates ──────────────────────────────────────────────────────
func _apply_lerped_environment() -> void:
	var env := _sky.environment
	# Fog
	env.fog_enabled   = _fog_density > 0.004
	env.fog_density   = _fog_density
	# Sky brightness
	var sky_energy    := lerpf(1.0, 0.3, _cloud_cover) * get_light_intensity()
	env.background_energy_multiplier = sky_energy
	# Ambient
	env.ambient_light_energy = lerpf(0.3, 0.1, _cloud_cover) * get_light_intensity() + 0.05


func _update_particle_systems() -> void:
	var is_snow := _current_weather in [WeatherState.LIGHT_SNOW, WeatherState.BLIZZARD]
	_rain_particles.emitting = _rain_intensity > 0.05 and not is_snow
	_snow_particles.emitting = _rain_intensity > 0.05 and is_snow
	_rain_particles.amount   = int(lerpf(0, 2000, _rain_intensity))
	_snow_particles.amount   = int(lerpf(0, 1500, _rain_intensity))


func _update_audio() -> void:
	_wind_audio.volume_db = linear_to_db(_wind_strength)
	_rain_audio.volume_db = linear_to_db(_rain_intensity)
	_wind_audio.playing   = _wind_strength > 0.1
	_rain_audio.playing   = _rain_intensity > 0.05


# ─── Lightning ────────────────────────────────────────────────────────────────
var _lightning_timer: float = 0.0

func _tick_lightning(delta: float) -> void:
	if _lightning_chance <= 0.0:
		return
	_lightning_timer -= delta
	if _lightning_timer <= 0.0:
		_lightning_timer = randf_range(3.0, 12.0) / _lightning_chance
		_trigger_lightning()


func _trigger_lightning() -> void:
	# Find a random position near the player
	var players := get_tree().get_nodes_in_group("players")
	if players.is_empty():
		return
	var player      := players[randi() % players.size()] as Node3D
	var offset       := Vector3(randf_range(-80, 80), 0.0, randf_range(-80, 80))
	var strike_pos   := player.global_position + offset
	_lightning.strike(strike_pos)
	# Deal area damage if close to player
	for p in players:
		if p.global_position.distance_to(strike_pos) < 5.0:
			var hit    := HitData.new()
			hit.damage  = 40.0
			hit.element = "lightning"
			CombatSystem.apply_hit(null, p, hit)


# ─── Gameplay Effects ─────────────────────────────────────────────────────────
func get_movement_modifier() -> float:
	match _current_weather:
		WeatherState.BLIZZARD:    return 0.6
		WeatherState.HEAVY_RAIN:  return 0.85
		WeatherState.SANDSTORM:   return 0.7
		_: return 1.0


func get_fire_damage_modifier() -> float:
	if _rain_intensity > 0.5:
		return 0.4  # Rain suppresses fire
	return 1.0


func get_visibility_range() -> float:
	return lerpf(200.0, 15.0, _fog_density / 0.08)


func set_biome(biome_id: String) -> void:
	if _current_biome != biome_id:
		_current_biome = biome_id
		_weather_timer = randf_range(30.0, 90.0)  # Re-roll weather soon
