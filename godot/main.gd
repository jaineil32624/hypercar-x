extends Node3D
## HYPERCAR-X Drive — Godot 4.3
## The car uses the Blender-baked GLB for visuals and VehicleBody3D for physics.
## Mass, power, torque, grip, drag and downforce come from variants.json, which
## is exported from the Python engineering model (reports/results.json).

const RHO := 1.225
const G := 9.81

var V: Dictionary = {}
var variant_keys: Array = []
var vi := 2  # start on C, Electric Hypercar

# swappable parts: [name, pro, con, effect dictionary]
var PARTS := {
	"Tyres": [
		["Performance", "All-weather, 40k km life", "Grip fades on track", {"mu": 0.0, "crr": 0.0}],
		["Semi-slick", "+15% grip, faster laps", "Unsafe in rain, 8k km life", {"mu": 0.2, "crr": 0.002}],
		["Eco low-RR", "+8-10% range", "Longer braking, less grip", {"mu": -0.2, "crr": -0.004}]],
	"Aero": [
		["Active wing", "DRS on straights, downforce in turns", "Actuator complexity", {"cl": 0.0, "cd": 0.0}],
		["Track pack", "2.5x downforce, 3 g corners", "More drag, less range", {"cl": 1.2, "cd": 0.13}],
		["No wing", "Lowest drag, best range", "Light rear at speed", {"cl": -0.7, "cd": -0.05}]],
	"Motors": [
		["Stock", "Per-wheel torque vectoring", "Heat at full power", {"p": 0.0, "m": 0.0}],
		["Overboost +350 kW", "Sub-2 s 0-60 potential", "Traction limited, +35 kg", {"p": 350.0, "m": 35.0}],
		["Eco -500 kW", "-48 kg, cheaper, simpler", "Half the power", {"p": -500.0, "m": -48.0}]],
}
var part_idx := {"Tyres": 0, "Aero": 0, "Motors": 0}

var car: VehicleBody3D
var visual: Node3D
var spins: Array = []
var steers: Array = []
var wheels: Array = []
var cam: Camera3D
var cam_mode := 0
var smoke: CPUParticles3D
var wing: Node3D

var hud_speed: Label
var hud_info: Label
var hud_times: Label
var hud_part: Label
var touch := {"accelerate": false, "brake": false, "steer_left": false, "steer_right": false}

var P := {}
var t_run := 0.0
var marks := {}
var steer := 0.0
var spin_angle := 0.0

func _ready() -> void:
	var f := FileAccess.open("res://variants.json", FileAccess.READ)
	V = JSON.parse_string(f.get_as_text())
	variant_keys = V.keys()
	variant_keys.sort()
	_build_world()
	_build_car()
	_build_hud()
	_apply_params()
	autotest = "--autotest" in OS.get_cmdline_user_args()

# ---------------------------------------------------------------- world
func _build_world() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.12, 0.2, 0.32)
	sm.sky_horizon_color = Color(0.75, 0.6, 0.45)
	sm.ground_horizon_color = Color(0.3, 0.28, 0.25)
	sky.sky_material = sm
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.glow_enabled = true
	e.fog_enabled = true
	e.fog_density = 0.0015
	e.fog_light_color = Color(0.6, 0.55, 0.5)
	env.environment = e
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, -40, 0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 120.0
	add_child(sun)

	# ground with asphalt-like checker
	var ground := StaticBody3D.new()
	var gm := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(3000, 3000)
	gm.mesh = plane
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.09, 0.095, 0.1)
	gmat.roughness = 0.9
	gm.material_override = gmat
	ground.add_child(gm)
	var gs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(3000, 1, 3000)
	gs.shape = box
	gs.position.y = -0.5
	ground.add_child(gs)
	add_child(ground)

	# drag strip lines every 50 m and a quarter-mile gate
	var line_mat := StandardMaterial3D.new()
	line_mat.albedo_color = Color(0.9, 0.9, 0.85)
	line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for i in range(0, 41):
		var l := MeshInstance3D.new()
		var lm := BoxMesh.new()
		lm.size = Vector3(0.15, 0.02, 3.0)
		l.mesh = lm
		l.material_override = line_mat
		for side in [-6.0, 6.0]:
			var c := l.duplicate()
			c.position = Vector3(side, 0.01, i * 10.0)
			add_child(c)
	var gate_mat := StandardMaterial3D.new()
	gate_mat.albedo_color = Color(0.21, 0.83, 0.77)
	gate_mat.emission_enabled = true
	gate_mat.emission = Color(0.21, 0.83, 0.77)
	gate_mat.emission_energy_multiplier = 2.0
	var gate := MeshInstance3D.new()
	var gmesh := BoxMesh.new()
	gmesh.size = Vector3(14, 0.3, 0.3)
	gate.mesh = gmesh
	gate.material_override = gate_mat
	gate.position = Vector3(0, 5, 402.3)
	add_child(gate)
	for side in [-7.0, 7.0]:
		var post := MeshInstance3D.new()
		var pm := BoxMesh.new()
		pm.size = Vector3(0.3, 5, 0.3)
		post.mesh = pm
		post.material_override = gate_mat
		post.position = Vector3(side, 2.5, 402.3)
		add_child(post)

	# slalom cones and a handling ring
	var cone_mat := StandardMaterial3D.new()
	cone_mat.albedo_color = Color(1, 0.45, 0.1)
	var cone_mesh := CylinderMesh.new()
	cone_mesh.top_radius = 0.02
	cone_mesh.bottom_radius = 0.25
	cone_mesh.height = 0.7
	for i in range(12):
		_cone(Vector3(40 + (i % 2) * 4.0, 0.35, -40 - i * 18.0), cone_mesh, cone_mat)
	for i in range(64):
		var a := TAU * i / 64.0
		for r in [60.0, 74.0]:
			_cone(Vector3(-120 + cos(a) * r, 0.35, -60 + sin(a) * r), cone_mesh, cone_mat)

	# jump ramp
	var ramp := StaticBody3D.new()
	var rm := MeshInstance3D.new()
	var rbox := BoxMesh.new()
	rbox.size = Vector3(8, 0.4, 14)
	rm.mesh = rbox
	var rmat := StandardMaterial3D.new()
	rmat.albedo_color = Color(0.2, 0.22, 0.25)
	rm.material_override = rmat
	ramp.add_child(rm)
	var rs := CollisionShape3D.new()
	var rsh := BoxShape3D.new()
	rsh.size = rbox.size
	rs.shape = rsh
	ramp.add_child(rs)
	ramp.position = Vector3(-40, 1.2, 60)
	ramp.rotation_degrees = Vector3(-10, 0, 0)
	add_child(ramp)

func _cone(pos: Vector3, mesh: Mesh, mat: Material) -> void:
	var c := RigidBody3D.new()
	c.mass = 2.0
	var m := MeshInstance3D.new()
	m.mesh = mesh
	m.material_override = mat
	c.add_child(m)
	var s := CollisionShape3D.new()
	var sh := CylinderShape3D.new()
	sh.radius = 0.2
	sh.height = 0.7
	s.shape = sh
	c.add_child(s)
	c.position = pos
	add_child(c)

# ---------------------------------------------------------------- car
func _build_car() -> void:
	car = VehicleBody3D.new()
	car.position = Vector3(0, 0.6, 0)
	car.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	car.center_of_mass = Vector3(0, 0.35, 0)
	car.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	car.linear_damp = 0.0  # aero drag is modelled explicitly
	add_child(car)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.85, 0.7, 4.4)
	shape.shape = box
	shape.position = Vector3(0, 0.58, 0)
	car.add_child(shape)

	# visual: Blender GLB rotated so the car's +X (Blender forward) faces Godot +Z
	visual = Node3D.new()
	car.add_child(visual)
	var packed: PackedScene = load("res://hypercar_x.glb")
	var inst := packed.instantiate()
	inst.rotation_degrees.y = -90
	visual.add_child(inst)
	_collect(inst)

	# physics wheels (no meshes; GLB wheels are the visuals)
	var positions := {"FL": Vector3(0.855, 0.48, 1.39), "FR": Vector3(-0.855, 0.48, 1.39),
		"RL": Vector3(0.83, 0.48, -1.39), "RR": Vector3(-0.83, 0.48, -1.39)}
	for tag in ["FL", "FR", "RL", "RR"]:
		var w := VehicleWheel3D.new()
		w.name = "W_" + tag
		w.position = positions[tag]
		w.wheel_radius = 0.355
		w.wheel_rest_length = 0.18
		w.suspension_travel = 0.12
		w.suspension_stiffness = 110.0
		w.damping_compression = 2.2
		w.damping_relaxation = 3.0
		w.suspension_max_force = 14000.0
		w.use_as_traction = true
		w.use_as_steering = tag.begins_with("F")
		w.wheel_roll_influence = 0.15
		car.add_child(w)
		wheels.append(w)

	cam = Camera3D.new()
	cam.fov = 65
	cam.far = 1500
	add_child(cam)
	cam.global_position = Vector3(0, 3, -8)

	smoke = CPUParticles3D.new()
	smoke.emitting = false
	smoke.amount = 120
	smoke.lifetime = 1.6
	smoke.direction = Vector3(0, 1, 0)
	smoke.spread = 40
	smoke.initial_velocity_min = 0.5
	smoke.initial_velocity_max = 2.0
	smoke.gravity = Vector3(0, 0.6, 0)
	smoke.scale_amount_min = 0.6
	smoke.scale_amount_max = 1.6
	smoke.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	smoke.emission_box_extents = Vector3(0.9, 0.05, 0.2)
	var sm := SphereMesh.new()
	sm.radius = 0.35
	sm.height = 0.7
	var smat := StandardMaterial3D.new()
	smat.albedo_color = Color(0.85, 0.87, 0.9, 0.25)
	smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.material = smat
	smoke.mesh = sm
	smoke.position = Vector3(0, 0.2, -1.6)
	car.add_child(smoke)

func _collect(n: Node) -> void:
	if n.name == "HX_Root" and n is Node3D:
		(n as Node3D).transform = Transform3D.IDENTITY
	if n is AnimationPlayer:
		(n as AnimationPlayer).stop()
	if String(n.name).begins_with("HX_Spin_"):
		spins.append(n)
	if String(n.name).begins_with("HX_Steer_F"):
		steers.append(n)
	if n.name == "HX_WingPivot":
		wing = n
	for c in n.get_children():
		_collect(c)

func _apply_params() -> void:
	var b: Dictionary = V[variant_keys[vi]]
	var ty: Dictionary = PARTS["Tyres"][part_idx["Tyres"]][3]
	var ae: Dictionary = PARTS["Aero"][part_idx["Aero"]][3]
	var mo: Dictionary = PARTS["Motors"][part_idx["Motors"]][3]
	P = {
		"mass": float(b["mass"]) + mo["m"],
		"power": (float(b["power_kw"]) + mo["p"]) * 1000.0,
		"torque": float(b["torque"]) * (float(b["power_kw"]) + mo["p"]) / float(b["power_kw"]),
		"gear": float(b["gear"]),
		"r": float(b["wheel_d"]) / 2.0,
		"mu": float(b["mu"]) + ty["mu"],
		"cd": float(b["cd"]) + ae["cd"],
		"cl": maxf(0.0, float(b["cl"]) + ae["cl"]),
		"area": float(b["area"]),
		"rpm": 21000.0,
	}
	car.mass = P["mass"]
	for w in wheels:
		w.wheel_friction_slip = P["mu"]
		w.suspension_max_force = P["mass"] * G * 1.6
	if wing:
		wing.visible = part_idx["Aero"] != 2
	_update_part_label()

# ---------------------------------------------------------------- HUD + touch
func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var theme_font := 22

	hud_speed = Label.new()
	hud_speed.add_theme_font_size_override("font_size", 64)
	hud_speed.add_theme_color_override("font_color", Color(0.9, 0.95, 1))
	hud_speed.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	hud_speed.position = Vector2(-90, -110)
	hud_speed.size = Vector2(180, 90)
	hud_speed.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(hud_speed)

	hud_info = _label(layer, Vector2(16, 12), theme_font, Color(0.21, 0.83, 0.77))
	hud_times = _label(layer, Vector2(16, 48), 18, Color(0.85, 0.9, 0.95))
	hud_part = _label(layer, Vector2(16, 150), 16, Color(0.8, 0.85, 0.9))

	# garage buttons (top right)
	var bx := VBoxContainer.new()
	bx.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	bx.position = Vector2(-250, 12)
	bx.size = Vector2(238, 0)
	layer.add_child(bx)
	_button(bx, "Variant  >", func(): vi = (vi + 1) % variant_keys.size(); _reset(); _apply_params())
	for slot in ["Tyres", "Aero", "Motors"]:
		var s: String = slot
		_button(bx, "Swap " + s + "  >", func(): part_idx[s] = (part_idx[s] + 1) % PARTS[s].size(); _apply_params())
	_button(bx, "Camera", func(): cam_mode = (cam_mode + 1) % 3)
	_button(bx, "Reset / Launch", func(): _reset())

	# touch driving pads
	_pad(layer, "◀", Vector2(24, -170), "steer_left")
	_pad(layer, "▶", Vector2(174, -170), "steer_right")
	_pad(layer, "BRAKE", Vector2(-330, -170), "brake", true)
	_pad(layer, "GAS", Vector2(-170, -170), "accelerate", true)

func _label(layer: CanvasLayer, pos: Vector2, size: int, col: Color) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("outline_size", 6)
	layer.add_child(l)
	return l

func _button(parent: Control, text: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(238, 52)
	b.add_theme_font_size_override("font_size", 20)
	b.pressed.connect(cb)
	b.focus_mode = Control.FOCUS_NONE
	parent.add_child(b)

func _pad(layer: CanvasLayer, text: String, pos: Vector2, action: String, right := false) -> void:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(140, 140)
	b.add_theme_font_size_override("font_size", 28)
	if right:
		b.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	else:
		b.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	b.position += pos
	b.size = Vector2(140, 140)
	b.modulate = Color(1, 1, 1, 0.55)
	b.button_down.connect(func(): touch[action] = true)
	b.button_up.connect(func(): touch[action] = false)
	layer.add_child(b)

func _update_part_label() -> void:
	var t := "GARAGE\n"
	for slot in ["Tyres", "Aero", "Motors"]:
		var p: Array = PARTS[slot][part_idx[slot]]
		t += "%s: %s\n   + %s\n   - %s\n" % [slot, p[0], p[1], p[2]]
	hud_part.text = t

func _reset() -> void:
	car.linear_velocity = Vector3.ZERO
	car.angular_velocity = Vector3.ZERO
	car.global_transform = Transform3D(Basis(), Vector3(0, 0.6, 0))
	t_run = 0.0
	marks.clear()

var autotest := false
var at_log := 0.0

func _pressed(a: String) -> bool:
	if autotest and a == "accelerate":
		return t_run < 14.0
	if autotest and a == "brake":
		return t_run >= 14.0
	return Input.is_action_pressed(a) or touch[a]

# ---------------------------------------------------------------- physics
func _physics_process(dt: float) -> void:
	var fwd := car.global_basis.z
	var v := car.linear_velocity.dot(fwd)
	var speed := car.linear_velocity.length()
	var thr := 1.0 if _pressed("accelerate") else 0.0
	var brk := 1.0 if _pressed("brake") else 0.0
	var s_in := (1.0 if _pressed("steer_left") else 0.0) - (1.0 if _pressed("steer_right") else 0.0)

	# tractive force = min(torque-limited, power-limited), same as the Python model
	var f_torque: float = P["torque"] * P["gear"] * 0.92 / P["r"]
	var f_power: float = P["power"] * 0.92 / maxf(absf(v), 1.0)
	# traction limit μ(mg + downforce), as in the Python model (Godot does not cap longitudinal grip itself)
	var q0 := 0.5 * RHO * v * v
	var f_grip: float = P["mu"] * (P["mass"] * G + q0 * P["cl"] * P["area"])
	var f := minf(minf(f_torque, f_power), f_grip) / 4.0  # Godot applies engine_force at each of the 4 traction wheels
	var v_motor_max: float = P["rpm"] * TAU / 60.0 / P["gear"] * P["r"]
	if v >= v_motor_max:
		f = 0.0
	if brk > 0.0 and v > 1.0:
		car.engine_force = 0.0
		car.brake = 0.04 * P["mass"] * P["mu"]
	elif brk > 0.0:
		car.engine_force = -f * 0.25  # reverse
		car.brake = 0.0
	else:
		car.engine_force = thr * f
		car.brake = 0.0 if thr > 0.0 else 3.0

	var max_steer := 0.55 / (1.0 + v * v / 900.0)
	steer = move_toward(steer, s_in * max_steer, dt * 2.5)
	car.steering = steer

	# aerodynamics: drag opposes motion, downforce pushes the car into the road
	var q := 0.5 * RHO * speed * speed
	if speed > 0.5:
		car.apply_central_force(-car.linear_velocity.normalized() * q * P["cd"] * P["area"])
	car.apply_central_force(-car.global_basis.y * q * P["cl"] * P["area"])

	# timing
	if v > 0.2 or thr > 0.0:
		t_run += dt
	var mph := v / 0.44704
	if not marks.has("0-60 mph") and mph >= 60:
		marks["0-60 mph"] = t_run
	if not marks.has("0-100 mph") and mph >= 100:
		marks["0-100 mph"] = t_run
	if not marks.has("1/4 mile") and car.global_position.z >= 402.3 and absf(car.global_position.x) < 8:
		marks["1/4 mile"] = t_run

	if autotest:
		at_log += dt
		if at_log >= 1.0:
			at_log = 0.0
			print("t=%.1f v=%.1f km/h z=%.1f y=%.2f marks=%s" % [t_run, v * 3.6, car.global_position.z, car.global_position.y, str(marks)])
		if t_run > 20.0:
			get_tree().quit()

	# wheel animation on the GLB
	spin_angle += v * dt / P["r"]
	for s in spins:
		(s as Node3D).rotation.z = -spin_angle
	for s in steers:
		(s as Node3D).rotation.y = steer
	if wing and wing.visible:
		var target := -0.66 if (brk > 0.0 and v > 15.0) else (-0.07 if v > 45.0 else -0.24)
		wing.rotation.z = lerpf(wing.rotation.z, target, 0.1)

	# smoke on wheelspin / hard slides
	var skid := false
	for w in wheels:
		if (w as VehicleWheel3D).get_skidinfo() < 0.5 and speed > 2.0:
			skid = true
	smoke.emitting = skid

func _process(dt: float) -> void:
	var back := -car.global_basis.z
	var target: Vector3
	match cam_mode:
		0:
			target = car.global_position + back * 7.5 + Vector3.UP * 2.4
		1:
			target = car.global_position + car.global_basis.z * 0.2 + Vector3.UP * 1.05
		_:
			target = car.global_position + Vector3(9, 4, 9)
	var k := 1.0 if cam_mode == 1 else 1.0 - exp(-dt * 6.0)
	cam.global_position = cam.global_position.lerp(target, k)
	var look := car.global_position + car.global_basis.z * (12.0 if cam_mode == 1 else 0.0) + Vector3.UP * 0.8
	cam.look_at(look, Vector3.UP)
	var speed := car.linear_velocity.length()
	cam.fov = lerpf(cam.fov, 65.0 + minf(25.0, speed * 0.25), 0.05)

	hud_speed.text = "%d\nkm/h" % int(speed * 3.6)
	hud_info.text = "HYPERCAR-X  %s · %s  ·  %d kg · %d kW" % [variant_keys[vi], V[variant_keys[vi]]["name"], int(P["mass"]), int(P["power"] / 1000.0)]
	var t := ""
	for k2 in ["0-60 mph", "0-100 mph", "1/4 mile"]:
		if marks.has(k2):
			t += "%s  %.2f s\n" % [k2, marks[k2]]
	hud_times.text = t if t != "" else "Hold GAS to launch · ¼-mile gate at 402 m"
