need a fetcher for portable pwsh latest or specific version pinned 

need to include modules in the pinned manifest for pwsh 

pwsh profile needs to include aliases for dotnet

pwsh profile needs to include commands for mcp client
 - doesn't UV handle the pswh-mcp-client script call?

 where do helper scripts for command center live?

 idea is for pwsh_exec to be self-contained. still need to make it pure UV without direct python dependency/invocation, like I did in codex-scientiae/procurement/mcp/server

 need a clean workflow for managing uv projects that run on both Windows and linux, where uv is fetched dynamically