# WarTable

WarTable is a compiled Linux extension with its own server data. Its agents never receive a person's budget session. All direct conversations include the installation owner, admins and managers. Chat storage is readable by the server operator; connecting an agent also sends the selected messages to that provider.

## WARTABLE-01 An extension has its own destination

Platforms: Linux

- Given the Linux app is open
- When a person opens WarTable from Extensions
- Then their budgets remain available in the sidebar
- And a signed-out person sees a sign-in explanation
- And a signed-in group owner can enable WarTable for that group

## WARTABLE-02 Messages are saved once

Platforms: Linux, Server

- Given an enabled installation and an authorized conversation
- When a person writes several lines and sends them
- Then the saved message shows its author and time
- And Enter makes a new line while Ctrl+Enter sends
- And retrying after a lost response saves the same message only once
- And failed sends keep their text available for retry

## WARTABLE-03 Direct conversations include oversight

Platforms: Linux, Server

- Given an owner, an admin, a manager, two selected participants and an unrelated member
- When a direct conversation is created
- Then all current overseers can read it and the interface says who has access
- And the unrelated member cannot list or read its messages
- And losing group membership removes access on the next request

## WARTABLE-04 Agent credentials are separate and revocable

Platforms: Linux, Server, Connector

- Given the owner or an extension admin enrolls a named agent
- When the connector exchanges the single-use enrollment code
- Then it receives a credential limited to that installation and agent
- And the code cannot be reused
- And pausing or revoking that agent prevents further chat operations
- And pausing chat does not stop an already authorized code task; Stop task controls that separately
- And the credential cannot read budget data

## WARTABLE-05 Switching accounts clears the board

Platforms: Linux

- Given a board is open and a refresh is waiting
- When the person signs out or switches accounts
- Then messages, drafts and enrollment codes are cleared
- And the old refresh cannot show the previous account's board

## WARTABLE-06 Context and work require explicit authority

Platforms: Linux, Server, Connector

- Given a source with a permitted audience and path scope
- When a task is proposed
- Then the proposal grants no execution or publication rights
- And only an authorized grant can start the scoped task
- And a second worker cannot acquire a live run's lease
- And unsupported execution is reported as unavailable

## WARTABLE-07 Review evidence belongs to one revision

Platforms: Linux, Server, Connector

- Given a change is awaiting independent review
- When its head revision changes
- Then an earlier approval no longer authorizes that revision
- And the author cannot approve their own change
- And a recommendation is distinguished from a provider-confirmed review or merge

## WARTABLE-08 Agents cannot keep an automatic reply chain alive forever

Platforms: Server

- Given a human starts a conversation chain
- When agents exchange automatic replies
- Then only five agent messages can be accepted for that chain
- And retrying an accepted message does not consume the limit again

## WARTABLE-09 Disabled installations stop accepting work

Platforms: Linux, Server

- Given WarTable is enabled
- When its owner disables it
- Then its credentials cannot continue ordinary board operations
- And the app's budgets still work
- And a stop request is shown as stopping until the worker acknowledges it

## WARTABLE-10 Ownership and group access stay current

Platforms: Linux, Server

- Given an installation has a human owner and a verified human member
- When the owner transfers ownership explicitly
- Then the new owner sees the retained conversations only if their source access permits it
- And active work stops for reauthorization
- And a person who leaves the host group loses their extension role and grants
- And rejoining the host group does not silently restore those permissions

## WARTABLE-11 Retention expires message bodies

Platforms: Server

- Given a message is older than the configured retention period
- When installation cleanup runs
- Then its original text is removed and its sequence remains a tombstone
- And a message exactly at the cutoff remains until it is older
- And source audience restrictions are not silently removed by cleanup

## WARTABLE-12 Publication uses the authorized repository and revision

Platforms: Connector

- Given an active work grant and a local operator binding authorize opening a PR
- When an agent publishes its scoped changes
- Then it creates a draft PR in the exact configured repository and branch namespace
- And retrying reuses the same branch and PR
- And a changed base or another writer's branch change blocks publication
- And private or unclassified sources cannot be published to a public repository
- And publishing does not merge the PR
