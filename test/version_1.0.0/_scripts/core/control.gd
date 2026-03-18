extends Control

# --- UI ---
@export var progress: ProgressBar
@export var label: Label
@export var speed_label: Label
@export var version_label: Label
@export var error_panel: Control
@export var error_label: Label
@export var retry_button: Button

# --- CONFIG ---
var manifest_url := "https://raw.githubusercontent.com/PixelStormStudio/test/main/manifest.json"
var local_manifest_path := "user://manifest.json"
var min_version := "1.0.0" # minimalna wersja offline

# --- STATE ---
var files: Array = []
var current_file := 0
var total_size := 0
var downloaded_total := 0
var server_version := "1.0.0" # domyślna minimalna wersja

# --- HTTP CLIENT ---
var client := HTTPClient.new()
var downloading := false
var current_file_size := 0
var current_downloaded := 0
var file_buffer := PackedByteArray()

# --- SPEED ---
var last_bytes := 0
var speed_timer: Timer

func _ready():
	retry_button.pressed.connect(_on_retry)

	speed_timer = Timer.new()
	speed_timer.wait_time = 0.5
	speed_timer.autostart = true
	speed_timer.timeout.connect(_update_speed)
	add_child(speed_timer)

	check_manifest()

# =========================
# --- MANIFEST CHECK ---
# =========================
func check_manifest():
	label.text = "Łączenie z serwerem..."
	error_panel.visible = false

	client.close()
	var err = client.connect_to_host("raw.githubusercontent.com", 443)
	if err != OK:
		# brak internetu → sprawdź lokalną wersję
		var local = load_local_manifest()
		var local_ver = local.get("version", null)
		if local_ver == null:
			_show_error("Brak lokalnej wersji gry — wymagane połączenie z internetem!")
			return
		elif is_version_ok(local_ver, min_version):
			print("Tryb offline")
			_after_update_check()
			return
		else:
			_show_error("Brak internetu i wymagana aktualizacja! Min: " + min_version)
			return

	downloading = true
	var data = await _http_request("/PixelStormStudio/test/main/manifest.json")
	if data.size() > 0:
		_process_manifest(data)
	else:
		var local = load_local_manifest()
		var local_ver = local.get("version", null)
		if local_ver != null and is_version_ok(local_ver, min_version):
			print("Nie udało się pobrać manifestu — offline fallback")
			_after_update_check()
		else:
			_show_error("Nie udało się pobrać manifestu i wymagana aktualizacja! Min: " + min_version)

# =========================
# --- HTTP REQUEST ---
# =========================
func _http_request(path: String) -> PackedByteArray:
	if not await _wait_connection():
		return PackedByteArray()

	var err = client.request(HTTPClient.METHOD_GET, path, [])
	if err != OK:
		print("Błąd wysyłania request:", err)
		return PackedByteArray()

	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		await get_tree().process_frame

	if client.get_status() != HTTPClient.STATUS_BODY:
		return PackedByteArray()

	var data := PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk = client.read_response_body_chunk()
		if chunk.size() > 0:
			data += chunk
		await get_tree().process_frame

	return data

# =========================
# --- PROCESS MANIFEST ---
# =========================
func _process_manifest(body: PackedByteArray):
	var json = JSON.parse_string(body.get_string_from_utf8())
	if json.error != OK:
		_show_error("Błąd JSON")
		return

	var server = json.result
	server_version = server.get("version", "1.0.0")
	var local = load_local_manifest()
	var local_ver = local.get("version", "0.0.0")

	version_label.text = "Twoja wersja: %s | Serwer: %s" % [local_ver, server_version]

	var server_min_ver = server.get("min_version", min_version)
	if not is_version_ok(local_ver, server_min_ver):
		_show_error("Musisz zaktualizować grę! Min: " + server_min_ver)
		return

	files.clear()
	total_size = 0

	for f in server["files"]:
		var local_v = local.get(f["name"], 0)
		if local_v < f["version"]:
			files.append(f)
			total_size += int(f["size"])

	if files.is_empty():
		label.text = "Wszystko aktualne!"
		progress.value = 100
		_after_update_check()
		return

	current_file = 0
	downloaded_total = 0
	download_next()

# =========================
# --- DOWNLOAD ---
# =========================
func download_next():
	if current_file >= files.size():
		label.text = "Zakończono!"
		progress.value = 100
		save_local_manifest(files, server_version)
		_after_update_check()
		return

	var f = files[current_file]

	label.text = "Pobieranie: " + f["name"]
	current_file_size = int(f["size"])
	current_downloaded = 0
	file_buffer.clear()

	client.close()
	client.connect_to_host("raw.githubusercontent.com", 443)

	var url = f["url"].replace("https://raw.githubusercontent.com", "")
	await _download_file(url, f["name"])

	current_file += 1
	download_next()

func _download_file(path: String, save_name: String):
	if not await _wait_connection():
		_show_error("Brak połączenia z internetem przy pobieraniu pliku!")
		return

	var err = client.request(HTTPClient.METHOD_GET, path, [])
	if err != OK:
		print("Błąd wysyłania request:", err)
		return

	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		await get_tree().process_frame

	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk = client.read_response_body_chunk()
		if chunk.size() > 0:
			file_buffer += chunk
			current_downloaded += chunk.size()
			downloaded_total += chunk.size()
			_update_progress()
		await get_tree().process_frame

	_save_file(save_name, file_buffer)

# =========================
# --- WAIT CONNECTION ---
# =========================
func _wait_connection() -> bool:
	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		client.poll()
		await get_tree().process_frame

	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		print("Nie udało się połączyć z serwerem!")
		return false
	return true

# =========================
# --- SAVE FILE ---
# =========================
func _save_file(name: String, data: PackedByteArray):
	var dir = DirAccess.open("user://")
	var folder = name.get_base_dir()
	if not dir.dir_exists(folder):
		dir.make_dir_recursive(folder)

	var f = FileAccess.open("user://" + name, FileAccess.WRITE)
	if f:
		f.store_buffer(data)
		f.close()

# =========================
# --- UI ---
# =========================
func _update_progress():
	progress.value = float(downloaded_total) / float(total_size) * 100
	var remaining = total_size - downloaded_total
	label.text = "Pozostało: " + _format_size(remaining)

func _update_speed():
	var diff = downloaded_total - last_bytes
	last_bytes = downloaded_total
	var speed = diff / speed_timer.wait_time
	speed_label.text = "Prędkość: " + _format_speed(speed)

func _format_size(b: int) -> String:
	if b >= 1024*1024:
		return "%.2f MB" % (b / (1024.0*1024.0))
	elif b >= 1024:
		return "%.2f KB" % (b / 1024.0)
	return "%d B" % b

func _format_speed(bps: float) -> String:
	if bps >= 1024*1024:
		return "%.2f MB/s" % (bps / (1024.0*1024.0))
	elif bps >= 1024:
		return "%.2f KB/s" % (bps / 1024.0)
	return "%.2f B/s" % bps

func _show_error(msg: String):
	error_panel.visible = true
	error_label.text = msg

func _on_retry():
	error_panel.visible = false
	check_manifest()

# =========================
# --- LOCAL MANIFEST ---
# =========================
func load_local_manifest() -> Dictionary:
	if FileAccess.file_exists(local_manifest_path):
		var f = FileAccess.open(local_manifest_path, FileAccess.READ)
		if f:
			var j = JSON.parse_string(f.get_as_text())
			f.close()
			if j.error == OK:
				return j.result
	return {}

func save_local_manifest(updated_files: Array, server_ver: String):
	var manifest = load_local_manifest()
	for f in updated_files:
		manifest[f["name"]] = f["version"]
	manifest["version"] = server_ver
	var file = FileAccess.open(local_manifest_path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(manifest))
		file.close()

# =========================
# --- VERSION CHECK ---
# =========================
func is_version_ok(local: String, minimum: String) -> bool:
	var l = local.split(".")
	var m = minimum.split(".")
	for i in range(max(l.size(), m.size())):
		var lv = int(l[i]) if i < l.size() else 0
		var mv = int(m[i]) if i < m.size() else 0
		if lv < mv:
			return false
		elif lv > mv:
			return true
	return true

# =========================
# --- OFFLINE FALLBACK ---
# =========================
func _after_update_check():
	get_tree().change_scene_to_file("res://_scenes/root.tscn")
