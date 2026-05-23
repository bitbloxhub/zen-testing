{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zen.url = "github:denful/zen";
  };

  outputs =
    inputs:
    let
      fx = import inputs.zen.inputs.nix-effects { lib = inputs.nixpkgs.lib; };
      ned = inputs.zen.inputs.ned.lib { inherit inputs; };
      bend = inputs.zen.inputs.bend.lib;
      zen = inputs.zen.lib;
    in
    {
      evaluations = {
        fx.auto-wired =
          let
            inherit (fx) bind pure;
            inherit (fx.effects) reader;

            lib = inputs.nixpkgs.lib;

            mkPrio = priority: value: {
              inherit priority value;
            };
            hiPrio = mkPrio 1000;
            normalPrio = mkPrio 500;
            lowPrio = mkPrio 100;

            asPrio = v: if builtins.isAttrs v && v ? priority && v ? value then v else normalPrio v;

            pick = old: new: if new.priority >= old.priority then new else old;

            mergeDelta =
              acc: delta:
              lib.foldlAttrs (
                a: k: v:
                let
                  next = asPrio v;
                  prev = a.${k} or null;
                in
                a
                // {
                  ${"${k}"} = if prev == null then next else pick prev next;
                }
              ) acc delta;

            modules = [
              (_env: {
                aa = lowPrio 1;
              })
              (_env: {
                aa = hiPrio 2;
              })
              (env: {
                b = env.aa + 1;
              })
              (env: {
                usesB = env.b * 10;
              })
            ];

            eval = bind (reader.asks (_env: modules)) (
              mods:
              bind (reader.ask) (
                _base:
                let
                  resolved = builtins.foldl' (
                    acc: modFn:
                    let
                      env = lib.mapAttrs (_: x: x.value) acc;
                      delta = modFn env;
                    in
                    mergeDelta acc delta
                  ) { } mods;
                  finalEnv = lib.mapAttrs (_: x: x.value) resolved;
                in
                pure finalEnv
              )
            );
          in
          fx.run eval reader.handler { };

        # TODO: do this right
        ned.free-ports =
          let
            aaa-d = _: ned.st 1;
            free-ports-c =
              { port }:
              {
                port = port.map (i: i + 1);
              };
          in
          {
            postgres = ned.run { port = aaa-d; } free-ports-c;
          };
        ned.actors = import ./actors.nix {
          inherit ned bend;
          actorsSystem = import ./actors-ned/actors-system.nix { inherit ned bend; };
        };
        zen.auto-wired = zen.run [
          {
            options.aa = zen.opt zen.merge.first zen.types.int;
            options.b = zen.opt zen.merge.first zen.types.int;
            options.usesB = zen.opt zen.merge.first zen.types.int;
          }
          (zen.defP 100 { aa = 1; })
          (cfg: { config.b = cfg.aa + 1; })
          (cfg: { config.usesB = cfg.b * 10; })
        ];

        zen.test1 = zen.run [
          {
            options.hosts = zen.opt zen.merge.attrs {
              get =
                raw:
                let
                  hostLens =
                    (zen.types.submod {
                      services = zen.types.submod {
                        cluster = zen.types.submod {
                          node_id = zen.types.singleLineStr;
                          cluster = zen.types.singleLineStr;
                        };
                      };
                    }).inner;
                  validated = (bend.eachValue hostLens).get raw;
                in
                if validated ? left then
                  validated
                else
                  let
                    hosts = validated.right;
                    clusterOf = hostName: hosts.${hostName}.services.cluster.cluster;
                    withPeers = builtins.mapAttrs (hostName: hostCfg: {
                      services.cluster = hostCfg.services.cluster // {
                        peers = builtins.filter (
                          otherHost: otherHost != hostName && clusterOf otherHost == clusterOf hostName
                        ) (builtins.attrNames hosts);
                      };
                    }) hosts;
                  in
                  bend.right withPeers;
              set = _: bend.right;
            };
          }
          (zen.def {
            hosts.alpha.services.cluster = {
              node_id = "1";
              cluster = "east";
            };
          })
          (zen.def {
            hosts.beta.services.cluster = {
              node_id = "2";
              cluster = "east";
            };
          })
          (zen.def {
            hosts.gamma.services.cluster = {
              node_id = "3";
              cluster = "west";
            };
          })
        ];
      };
    };
}
