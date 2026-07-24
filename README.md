# Okta Enabled Server

This is a module that stands up an instsance with an okta-enabled server

## Okta membership changes

The instance's cloud-init embeds a point-in-time snapshot of OktaPAM group
membership (`groups_and_users`), but `user_data` is in `ignore_changes`, so
membership drift never stops or replaces a running instance. To reconcile a
running server with current Okta membership, regenerate the data file and
re-run the playbook on the box:

```sh
scripts/gen_groups_and_users.py --json -o groups_and_users.json
# copy groups_and_users.json to /root on the server, then:
ansible-playbook -i localhost, -c local /root/update_users.yml -e @/root/groups_and_users.json
```

To rebuild an instance after intentional cloud-init or template changes:

```sh
tofu apply -replace=aws_instance.this
```
