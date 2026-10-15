# Developing exeslim

This repo builds exeslim, a minimal exe.dev base image for single-service
deployment VMs. This file is for agents working on the repo.

`image/agent-context.md` is not addressed to you. The Dockerfile copies it into
the image as `~/.config/shelley/AGENTS.md`, for agents running on VMs booted
from exeslim. Edit it only to change what those agents are told.