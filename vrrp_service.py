#!/usr/bin/env python3
import os
import json
import subprocess
from flask import Flask, request, jsonify

app = Flask(__name__)

CONF_DIR = "/etc/vrrp/conf.d"
CONF_PATH = os.path.join(CONF_DIR, "conf.json")
VRRP_SCRIPT = os.environ.get("VRRP_SCRIPT", "/usr/local/sbin/vrrp.sh")


def ensure_conf_dir():
    os.makedirs(CONF_DIR, exist_ok=True)


def run_vrrp_script(action: str):
    """
    Helper to call the vrrp.sh script.
    Returns a dict with returncode, stdout, stderr or an error.
    """
    try:
        result = subprocess.run(
            [VRRP_SCRIPT, action],
            capture_output=True,
            text=True,
        )
        return {
            "returncode": result.returncode,
            "stdout": result.stdout,
            "stderr": result.stderr,
        }
    except FileNotFoundError:
        return {"error": f"{VRRP_SCRIPT} not found"}
    except Exception as e:
        return {"error": f"failed to execute {VRRP_SCRIPT}: {e}"}


@app.route("/vrrp", methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"])
def vrrp_handler():
    # OPTIONS preflight (CORS / generic)
    if request.method == "OPTIONS":
        return ("", 204)

    # GET: return current config + status
    if request.method == "GET":
        if not os.path.exists(CONF_PATH):
            return jsonify({"error": "config not found"}), 404

        try:
            with open(CONF_PATH, "r") as f:
                data = json.load(f)
        except Exception as e:
            return jsonify({"error": f"failed to read config: {e}"}), 500

        status = run_vrrp_script("status")

        return jsonify({
            "config": data,
            "status": status,
        }), 200

    # POST / PUT: save config and apply
    if request.method in ("POST", "PUT"):
        if not request.is_json:
            return jsonify({"error": "JSON body required"}), 400

        payload = request.get_json()
        if "vrrp" not in payload:
            return jsonify({"error": "top-level 'vrrp' key missing"}), 400

        ensure_conf_dir()
        tmp_path = CONF_PATH + ".tmp"
        try:
            with open(tmp_path, "w") as f:
                json.dump(payload, f, indent=2)
            os.replace(tmp_path, CONF_PATH)
        except Exception as e:
            return jsonify({"error": f"failed to write config: {e}"}), 500

        # Apply to the node via shell script
        script_result = run_vrrp_script("create")

        http_code = 200
        if isinstance(script_result, dict) and script_result.get("returncode", 0) != 0:
            http_code = 500

        return jsonify({
            "message": "config saved",
            "script": script_result,
        }), http_code

    # DELETE: remove config and tear down VRRP/VxLAN
    if request.method == "DELETE":
        script_result = run_vrrp_script("delete")

        if os.path.exists(CONF_PATH):
            try:
                os.remove(CONF_PATH)
            except Exception as e:
                return jsonify({
                    "message": "delete attempted, but failed to remove config file",
                    "file_error": str(e),
                    "script": script_result,
                }), 500

        return jsonify({
            "message": "config deleted (if it existed)",
            "script": script_result,
        }), 200


if __name__ == "__main__":
    # Adjust host/port as needed
    app.run(host="0.0.0.0", port=8080, debug=False)
