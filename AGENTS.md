# Machine management agent instructions

For throwaway/test containers use `docker run --rm` and a unique
`--label agent.session=<Hub session id>` (or native session id registered in Hub).
Apply that label to `docker create` and Compose test containers too. Install
shell `trap` or `try/finally` cleanup before creating resources; remove everything
you create before the session exits, including failed starts. Preserve production
data, volumes, unrelated containers and all Coolify-managed containers.
