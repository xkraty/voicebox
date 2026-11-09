# Voicebox — Kamal deploy

Deploys [Voicebox](https://github.com/jamiepine/voicebox) (web UI + API) to
`voice.campoli.me` with Kamal, on the same host as campoli and paseo. TLS comes
from kamal-proxy via Let's Encrypt.

```
internet ──443──▶ kamal-proxy ──▶ voice container
                  (TLS)            ├─ Caddy :8080  (basic auth, app_port)
                                   └─ Voicebox 127.0.0.1:17493 (never exposed)
```

Voicebox has no authentication and no published image. So the `Dockerfile`
builds it from source at a pinned commit (`VOICEBOX_REF`) and bundles Caddy in
the same container. Caddy does basic auth in front of Voicebox. `/up` stays
open for the kamal-proxy health check.

What the Dockerfile changes compared to upstream's:

- **CPU-only PyTorch.** Upstream's default build pulls the CUDA wheels
  (~3 GB of nvidia libraries this server can't use).
- **No Chatterbox.** LuxTTS only. Voicebox has no switch to hide engines, so
  Chatterbox TTS and Turbo still appear in the model list. Picking one fails
  with an import error, so don't download them.
- **Caddy + `bin/voice-start`**: runs both processes. If either one dies, the
  container exits and Docker restarts it.

## Engine: LuxTTS

LuxTTS gives fast voice cloning with 48 kHz output, and it's Voicebox's
fastest engine on CPU (model ~300 MB). Download it once from the UI. It's kept
in the `voice_models` volume.

## Setup

1. **Point DNS at the host.** Add an A record `voice.campoli.me` →
   `49.12.87.239` *before* the first deploy. Kamal SSHes to that name, and the
   Let's Encrypt challenge needs it.

2. **Resources.** Voicebox needs at least 8 GB RAM for one engine. thor has
   62 GB and 20 threads, so the container is capped at 16 GB / 10 CPUs in
   `config/deploy.production.yml`. Without a GPU, more CPUs means faster
   generation. The image plus models need about 10 GB of disk.

3. **1Password.** Create a "Voice" item in the Kamal vault with
   `KAMAL_REGISTRY_USERNAME`, `KAMAL_REGISTRY_PASSWORD` (a GHCR token with
   `write:packages`) and `VOICE_PASSWORD` (the basic-auth password; the user
   is `admin`, set in `config/deploy.yml`).

4. **Create `.env.production`** (gitignored). It holds only `op://` references:

```
KAMAL_REGISTRY_USERNAME=op://Kamal/Voice/KAMAL_REGISTRY_USERNAME
KAMAL_REGISTRY_PASSWORD=op://Kamal/Voice/KAMAL_REGISTRY_PASSWORD
VOICE_PASSWORD=op://Kamal/Voice/VOICE_PASSWORD
```

5. **Install:**

```bash
bundle install
```

## Deploy

Kamal builds from a clean clone of `HEAD`, so commit before deploying.

kamal-proxy already runs on the host, so `kamal setup` isn't needed:

```bash
op run --env-file .env.production -- bin/kamal deploy -d production
```

CI does the same on a published release or a manual run (Actions → Deploy),
with secrets from the `OP_SERVICE_ACCOUNT_TOKEN` repo secret. The first build
takes a while: torch plus every engine. Later builds reuse the registry cache
(`ghcr.io/xkraty/voicebox-build-cache`).

## Upgrading Voicebox

1. Pick the new commit or tag on github.com/jamiepine/voicebox.
2. Diff upstream's `Dockerfile` between the old and new `VOICEBOX_REF` and
   carry any build changes over into ours.
3. Bump `VOICEBOX_REF`, commit, deploy.

## Operating

```bash
bin/kamal app logs -f -d production
```

```bash
bin/kamal app exec --reuse -d production bash
```

Changing the password: update `VOICE_PASSWORD` in 1Password, then redeploy
(the container hashes it for Caddy on start).

Data lives in Docker volumes on the host: `voice_data` (profiles, DB,
generations) and `voice_models` (downloaded models).

Voice cloning: only clone voices you have consent for. See Voicebox's
`RESPONSIBLE_USE.md`.
