# Running EFMS

EFMS is a web application for managing an experimental farm. This repository exist to propose an easy way to get it running, whether that is on your own laptop to try it out or on a server.

All you need is to copy-paste a few commands and answer a few questions. It will create the database, the backend and the frontend for you.

## How it works

EFMS is made of three pieces that have to run together: a **database** (where everything is stored), a **backend** (the engine that does the work) and a **frontend** (the website you use to interact with EFMS). Setting up three programs by hand is not trivial, so we use **Docker**. Docker is a tool that runs each piece inside its own sealed, ready-made container, so your computer only has to start the containers instead of installing and configuring everything itself. You install Docker once, and it handles the rest.

## What you need

- A computer that can stay turned on. For just trying EFMS, your own machine is fine. If other people need to reach it, you want a server, meaning a machine that stays on and is reachable over the network.
- Docker, installed (see just below).
- About 2 GB of free disk space.
- A terminal. That is the PowerShell app on Windows, the Terminal app on macOS, or whatever terminal your Linux uses. Everything below is meant to be run in a terminal.

### Installing Docker

- **Windows or macOS:** install Docker Desktop from <https://www.docker.com/products/docker-desktop/>. Open it once after installing and wait until it says it is running.
- **Linux:** follow <https://docs.docker.com/engine/install/> for your distribution. Make sure the Compose plugin comes with it (on most distributions it does).

To check it is ready, type this in a terminal and look for a version number rather than an error:

```sh
docker --version
```

## The easy way (recommended)

This repository comes with a small installer that checks everything is in place, sets up your passwords and settings for you, and starts EFMS.

First, download the files. In a terminal:

```sh
git clone https://github.com/W-EFMS/EFMS-deploy.git
cd EFMS-deploy
```

(No `git`? You can instead download this repository as a ZIP from its web page, unzip it, and open a terminal inside the unzipped folder.)

Then run the installer.

On Linux or macOS:

```sh
./install.sh
```

On Windows, in PowerShell:

```powershell
PowerShell -ExecutionPolicy Bypass -File .\install.ps1
```

It will ask you a few questions. Here is what each one means and what to answer:

- **"generate a random jwt secret?"** Say yes. This is a secret key the app uses to keep logins safe. Letting it create a random one is exactly what you want.
- **"generate a random db password?"** Say yes, same idea, this time for the database.
- **"api url for the browser"** This is the only question that needs a moment of thought. See the short box below. If you are just trying EFMS on your own computer, press Enter to take the default.
- **"frontend port" / "backend port"** These are the numbered doors on your machine that EFMS uses. Press Enter to accept 3000 and 8080, unless the installer warns you one is already taken.

At the end it shows a summary and asks "go?". Say yes, and it downloads the boxes and starts everything.

### What is this "api url"?

The website runs inside your visitor's browser and that browser needs to know where to find the backend.

- **Trying it on your own computer:** leave it as `http://localhost:8080`. "localhost" just means "this same computer".
- **Putting it on a server for other people:** set it to where they will reach the backend, for example `http://203.0.113.5:8080` (your server's address) or `https://efms.yourfarm.be` if you have a domain name. Do not use "localhost" here, because to your visitors "localhost" would mean their own computer, not your server.

## Did it work?

Open a browser and go to <http://localhost:3000>. If you set it up on a server with your own address, use that instead.

You should see the EFMS login page.

If not, see the **When something goes wrong** section below.

To double-check the pieces are healthy, run:

```sh
docker compose ps
```

You want to see the services listed as running or healthy.

## Day to day

Run these from inside the `EFMS-deploy` folder.

| What you want | Command |
| --- | --- |
| Watch what is happening, read errors | `docker compose logs -f` (Ctrl+C to stop watching) |
| Stop EFMS but keep all data | `docker compose down` |
| Start it again | `docker compose up -d` |
| Update to the newest version | `docker compose pull` then `docker compose up -d` |
| Stop and erase everything, database included | `docker compose down -v` |


EFMS restarts on its own if the machine reboots, so you do not have to watch over it.

### Backing up your data

Everything important lives in the database. To save a copy to a file:

```sh
docker compose exec postgres pg_dump -U efms efms_db > efms-backup.sql
```

That writes a file called `efms-backup.sql` in the current folder. Keep it somewhere safe, ideally on a different machine. 
Don't forget to backup the hidden `.env` file as well as it contains your passwords and other settings required to get the farm running again.

## Exposing to the Internet (HTTPS)

If you are running EFMS on a server and want to make it securely accessible over the internet, we recommend using **Nginx Proxy Manager (NPM)**. NPM provides a friendly web interface to route traffic to your containers and automatically fetches free Let's Encrypt SSL certificates.

1. **Use the NPM Compose File:** Start your stack using the `docker-compose.nginx.yml` file, which includes NPM and comments out the direct port mappings for the frontend and backend.
   ```sh
   docker compose -f docker-compose.nginx.yml up -d
   ```
2. **Access the NPM UI:** Open `http://<your-server-ip>:81` in your browser. Log in with the default credentials:
   - Email: `admin@example.com`
   - Password: `changeme`
   *(It will immediately ask you to change these)*
3. **Add Proxy Hosts:** In NPM, go to **Hosts -> Proxy Hosts** and click **Add Proxy Host**.
   - **Frontend:** Domain Names: `efms.yourfarm.be`, Scheme: `http`, Forward Hostname / IP: `efms-frontend` (or `frontend`), Forward Port: `3000`. Go to the **SSL** tab, select "Request a new SSL Certificate", check "Force SSL", agree to the Terms of Service, and hit Save.
   - **Backend:** Domain Names: `api.efms.yourfarm.be`, Scheme: `http`, Forward Hostname / IP: `efms-backend` (or `backend`), Forward Port: `8080`. Go to the **SSL** tab, select "Request a new SSL Certificate", check "Force SSL", agree to the Terms of Service, and hit Save.
4. **Update EFMS:** Update your `.env` file so `API_URL` points to your secure backend (e.g., `https://api.efms.yourfarm.be`) and restart EFMS.

This approach keeps your backend, frontend, and database securely isolated from the outside network, forcing all external traffic to be encrypted and routed exclusively through the proxy.

## When something goes wrong

The usual culprits, and what to do:

- **Commands fail with something about the "docker daemon".** Docker itself is not started. On Windows or macOS, open Docker Desktop and wait for it to say running. On Linux, start it with `sudo systemctl start docker`.
- **The page will not load at all.** On the very first start, give it a minute, it is still unpacking. Then run `docker compose ps`. If a piece is not up, `docker compose logs` usually tells you why.
- **The page loads but you cannot log in or nothing happens.** This is almost always the api url: the backend address the browser is told to use does not match where the backend actually is. Open the `.env` file, fix `API_URL`, then run `docker compose up -d`.
- **It says a port is busy.** Something else on the machine is already using 3000 or 8080. Either stop that other program, or set `FRONTEND_PORT` and `BACKEND_PORT` in `.env` to free numbers and run `docker compose up -d`.
- **You changed the database password and now the database will not start.** The old password is still baked into the existing data. If you do not need that data, wipe it with `docker compose down -v` and start over. That deletes everything, so only do it if you are sure.

## The manual way (if you would rather skip the installer)

```sh
cp .env.example .env
# open .env in a text editor, then set DB_PASS and JWT_SECRET to your own values
docker compose up -d
```

Everything is controlled by that one `.env` file:

| Setting | What it does |
| --- | --- |
| `DB_USER`, `DB_PASS`, `DB_NAME` | the database account and the database name |
| `JWT_SECRET` | secret key that secures logins, at least 32 characters, change it before any real deployment |
| `API_URL` | where the browser reaches the backend (see the box above) |
| `FRONTEND_PORT`, `BACKEND_PORT` | which ports on your machine to use |
| `BACKEND_TAG`, `FRONTEND_TAG` | which version of the images to run; pin these to a release tag instead of `latest` if you want an unchanging setup |

## What is actually running

| Piece | Image | Reachable on your machine |
| --- | --- | --- |
| Frontend (the website) | `ghcr.io/w-efms/efms-frontend` | port 3000 |
| Backend (the engine) | `ghcr.io/w-efms/efms-backend` | port 8080 |
| Database | `postgis/postgis:15-3.3` | internal only, not exposed |

The database is deliberately kept inside Docker's private network and is not opened up on the machine, so nothing outside can reach it directly. The backend talks to it over that private network.
