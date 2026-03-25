# Swarm Backlog

### Evaluate Hetzner as cheaper alternative to AWS EC2
Running r6i.xlarge 24/7 costs ~$183/month. Hetzner CCX33 (32GB, 8 vCPUs) is ~$38/month for comparable specs. US data center available (Ashburn VA). Same workflow — SSH, Docker, Claude Code. Only need compute, no AWS services.
- [ ] Spin up Hetzner CCX33, test swarm end-to-end
- [ ] Compare: container performance, API latency to Anthropic, git clone speeds
- [ ] If comparable, migrate and terminate AWS instance

