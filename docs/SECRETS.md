# Secrets Management

This project uses [SOPS](https://github.com/mozilla/sops) with age encryption to manage secrets securely, following the same pattern as deepdarshak-backend.

## Files

- **`.env.secrets`** - Encrypted GPU API keys (tracked in git, safe to commit)
- **`.env.secrets.plain`** - Temporary plaintext file during editing (automatically deleted, gitignored)
- **`.age-key.txt`** - Age private encryption key (gitignored, DO NOT COMMIT)
- **`~/.sops.yaml`** or **`.sops.yaml`** - SOPS configuration

## Key Information

- **Public key**: `age157j9txae49dms0mz7wz8dgm5ku9xe0anxd4vdch7e69usydn5c9qfufkjs`
- **Shared with**: deepdarshak-backend (same age key for workspace consistency)
- **Private key location**: `/home/crimson/projects/gpu-inference-stack/.age-key.txt`

## Usage

### Viewing Secrets

```bash
export SOPS_AGE_KEY_FILE=/home/crimson/projects/gpu-inference-stack/.age-key.txt
sops -d .env.secrets
```

### Editing Secrets

```bash
export SOPS_AGE_KEY_FILE=/home/crimson/projects/gpu-inference-stack/.age-key.txt
sops .env.secrets
```

SOPS will:
1. Decrypt the file
2. Open it in your `$EDITOR`
3. Re-encrypt it when you save and close

### Adding New Secrets

1. Edit the encrypted file:
   ```bash
   sops .env.secrets
   ```

2. Add your secret in the format:
   ```bash
   SECRET_NAME=secret_value
   ```

3. Save and close. SOPS automatically re-encrypts.

## Available Secrets

### UI_USERNAME / UI_PASSWORD

LiteLLM admin UI credentials. Set via:

```bash
make set-passwd
```

This prompts for a username (default: `admin`) and password, then stores them
encrypted in `.env.secrets`. The credentials are loaded automatically when
`scripts/dc.sh` runs, passed to the litellm container as `UI_USERNAME` and
`UI_PASSWORD`.

- **Default username**: `admin`
- **Default password**: (none — falls back to master key if unset)

### GPU_CRIMSON_LLM2_KEY

API key for the crimson-llm2 GPU server.

- **Server**: RTX PRO 6000 Blackwell, 97 GB VRAM
- **URL**: http://100.117.227.85:8080
- **Alias**: ember-deepdrishti
- **Models**: gpu/chat/interactive, gpu/chat/bulk, gpu/chat/fast, gpu/embed/bge-m3, gpu/rerank/bge-reranker-v2-m3
- **Rate Limit**: 600 RPM
- **Generated**: 2026-09-16

The corresponding URL `GPU_CRIMSON_LLM2_URL` is in `.env.example` (safe to commit).

## Security Notes

- **`.env.secrets`** is encrypted and safe to commit to git
- **`.age-key.txt`** is the private key and MUST NEVER be committed
- **`.env.secrets.plain`** (temporary plaintext) is gitignored
- The same age key is shared with deepdarshak-backend for workspace consistency
- Always use the `SOPS_AGE_KEY_FILE` environment variable to point to the key

## Backup

The age key is already backed up as part of the deepdarshak workspace. If you need to restore it:

```bash
cp /home/crimson/projects/project-deepdarshak/deepdarshak-backend/.age-key.txt \
   /home/crimson/projects/gpu-inference-stack/.age-key.txt
```

## Pattern Consistency

This follows the same pattern as `deepdarshak-backend/shared/config/.env.secrets`:

1. Encrypted secrets tracked in git (`.env.secrets`)
2. Private key not tracked (`.age-key.txt` in `.gitignore`)
3. SOPS configuration in `~/.sops.yaml` or local `.sops.yaml`
4. Same age public key across the workspace

## Troubleshooting

### "no key could be found"

Make sure `SOPS_AGE_KEY_FILE` is set:

```bash
export SOPS_AGE_KEY_FILE=/home/crimson/projects/gpu-inference-stack/.age-key.txt
```

### "failed to decrypt"

Verify you have the correct age private key:

```bash
age-keygen -y /home/crimson/projects/gpu-inference-stack/.age-key.txt
```

Should output: `age157j9txae49dms0mz7wz8dgm5ku9xe0anxd4vdch7e69usydn5c9qfufkjs`
