"""核心链路冒烟测试。"""


def test_health(client):
    r = client.get("/api/health")
    assert r.status_code == 200
    assert r.json()["service"] == "cubestackinstaller-api"


def test_admin_login(client):
    r = client.post("/api/auth/login", json={"account": "admin", "password": "admin@123"})
    assert r.status_code == 200
    data = r.json()
    assert data["user"]["role"] == "admin"
    assert data["access_token"]


def test_register_then_login(client):
    r = client.post(
        "/api/auth/register",
        json={"username": "tester", "email": "tester@example.com", "password": "secret123"},
    )
    assert r.status_code == 201
    r2 = client.post("/api/auth/login", json={"account": "tester", "password": "secret123"})
    assert r2.status_code == 200
    assert r2.json()["user"]["username"] == "tester"


def test_unauthorized_rejected(client):
    assert client.get("/api/hosts").status_code == 401


def test_hosts_and_providers(client):
    token = _admin_token(client)
    assert client.get("/api/hosts", headers=_auth(token)).status_code == 200
    r = client.get("/api/vms/providers", headers=_auth(token))
    assert r.status_code == 200
    keys = {p["key"] for p in r.json()}
    assert keys == {"libvirt", "kubevirt"}


def test_vm_create_task_flow(client):
    token = _admin_token(client)
    r = client.post(
        "/api/vms",
        headers=_auth(token),
        json={"name": "test-vm", "host_id": 1, "cpu": 2, "memory_gb": 4,
              "disk_gb": 20, "image": "ubuntu-22.04-cloud.qcow2"},
    )
    assert r.status_code == 202
    task_id = r.json()["task_id"]

    # 轮询任务直至完成
    import time
    for _ in range(20):
        t = client.get("/api/tasks/" + str(task_id), headers=_auth(token)).json()
        if t["status"] in ("success", "failed"):
            break
        time.sleep(0.3)
    assert t["status"] == "success"
    assert t["progress"] == 100


def _admin_token(client):
    r = client.post("/api/auth/login", json={"account": "admin", "password": "admin@123"})
    return r.json()["access_token"]


def _auth(token):
    return {"Authorization": "Bearer " + token}
