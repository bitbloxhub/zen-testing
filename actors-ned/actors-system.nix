{
  ned,
  bend,
}:
let
  warn = builtins.warn or (msg: v: builtins.trace "[1;35mevaluation warning:[0m ${msg}" v);

  msgEnvelopeLens = bend.recordAll {
    to = bend.str;
    from = bend.str;
    type = bend.str;
    payload = bend.identity;
  };

  cmdSendLens = bend.recordAll {
    op = bend.str;
    to = bend.str;
    type = bend.str;
    payload = bend.identity;
  };

  cmdSpawnLens = bend.recordAll {
    op = bend.str;
    name = bend.str;
    actor = bend.identity;
  };

  msg = {
    mkLens =
      payloadLens:
      bend.recordAll {
        to = bend.str;
        from = bend.str;
        type = bend.str;
        payload = payloadLens;
      };
  };

  mkActor =
    {
      state ? { },
      lenses ? { },
      on ? { },
      stateLens ? bend.identity,
    }:
    let
      defaultStep =
        actorId: actor: m:
        if builtins.stringLength m.type >= 5 && builtins.substring 0 5 m.type == "$sys." then
          {
            state = actor.state or { };
            commands = [ ];
            events = [ ];
          }
        else
          {
            state = actor.state or { };
            commands = [ ];
            events = [
              {
                kind = "unhandled";
                actor = actorId;
                type = m.type;
              }
            ];
          };

      step =
        actorId: actor: m:
        let
          handler = on.${m.type} or null;
          out = if handler == null then defaultStep actorId actor m else handler actorId actor m;
          candidate = out.state or (actor.state or { });
          checked = stateLens.get candidate;
        in
        if checked ? left then
          builtins.deepSeq (warn "[actors-system-cycle] invalid-state actor=${actorId}" null) {
            state = actor.state or { };
            commands = [ ];
            events = (out.events or [ ]) ++ [
              {
                kind = "invalid-state";
                actor = actorId;
                got = candidate;
                parse = checked.left;
              }
            ];
          }
        else
          {
            state = checked.right;
            commands = out.commands or [ ];
            events = out.events or [ ];
          };
    in
    {
      inherit step state stateLens;
      messageParsers = lenses;
    };

  cmd = {
    send =
      {
        to,
        type,
        payload,
      }:
      {
        op = "send";
        inherit to type payload;
      };
    spawn =
      { name, actor }:
      {
        op = "spawn";
        inherit name actor;
      };
  };

  mailbox-d = msg-s: msg-s;

  stripFns =
    s:
    s
    // {
      actors = builtins.mapAttrs (
        _: a:
        builtins.removeAttrs a [
          "step"
          "messageParsers"
          "stateLens"
        ]
      ) s.actors;
    };

  errSummary =
    err:
    let
      parts = builtins.filter (x: x != "") [
        (if err ? actor then "actor=${err.actor}" else "")
        (if err ? by then "by=${err.by}" else "")
        (if err ? op then "op=${err.op}" else "")
        (if err ? type then "type=${err.type}" else "")
        (if err ? id then "id=${err.id}" else "")
        (if err ? to then "to=${err.to}" else "")
      ];
    in
    if parts == [ ] then err.kind else "${err.kind} " + builtins.concatStringsSep " " parts;

  runtimeCore =
    {
      actors,
      queue,
      events,
      mode,
    }:
    let
      onError =
        s: err:
        let
          _w = warn "[actors-system-cycle] ${errSummary err}" null;
          s1 = s // {
            errors = (s.errors or [ ]) ++ [ err ];
          };
        in
        builtins.deepSeq _w (
          if mode == "strict" then
            s1
            // {
              halted = true;
              haltError = err;
              queue = [ ];
            }
          else
            s1
        );

      applyCommand =
        senderId: s: command:
        let
          op = command.op or "";
        in
        if op == "send" then
          let
            parsed = cmdSendLens.get command;
          in
          if parsed ? left then
            onError s {
              kind = "bad-command";
              op = "send";
              by = senderId;
              parse = parsed.left;
              input = command;
            }
          else
            s
            // {
              queue = s.queue ++ [ ({ from = senderId; } // builtins.removeAttrs parsed.right [ "op" ]) ];
            }
        else if op == "spawn" then
          let
            parsed = cmdSpawnLens.get command;
          in
          if parsed ? left then
            onError s {
              kind = "bad-command";
              op = "spawn";
              by = senderId;
              parse = parsed.left;
              input = command;
            }
          else
            let
              id = parsed.right.name;
            in
            if s.actors ? ${"${id}"} then
              onError s {
                kind = "spawn-collision";
                by = senderId;
                id = id;
              }
            else
              s
              // {
                actors = s.actors // {
                  ${"${id}"} = parsed.right.actor;
                };
                queue = s.queue ++ [
                  {
                    to = senderId;
                    from = "system";
                    type = "$sys.spawned";
                    payload = {
                      name = parsed.right.name;
                      id = id;
                    };
                  }
                ];
                events = s.events ++ [
                  {
                    kind = "spawned";
                    by = senderId;
                    id = id;
                    name = parsed.right.name;
                  }
                ];
              }
        else
          onError s {
            kind = "unknown-command";
            by = senderId;
            command = command;
          };

      stepOne =
        s:
        if s.queue == [ ] || (s.halted or false) then
          s
        else
          let
            rawMsg = builtins.head s.queue;
            rest = builtins.tail s.queue;
            parsed = msgEnvelopeLens.get rawMsg;
          in
          if parsed ? left then
            onError (s // { queue = rest; }) {
              kind = "bad-message";
              parse = parsed.left;
              input = rawMsg;
            }
          else
            let
              m = parsed.right;
              actor = s.actors.${m.to} or null;
            in
            if actor == null then
              onError (s // { queue = rest; }) {
                kind = "dead-letter";
                to = m.to;
                type = m.type;
              }
            else
              let
                isSys = builtins.stringLength m.type >= 5 && builtins.substring 0 5 m.type == "$sys.";
                parsedForActor =
                  if isSys then
                    { right = m; }
                  else
                    let
                      p = actor.messageParsers.${m.type} or null;
                    in
                    if p == null then null else p.get m;
              in
              if !isSys && parsedForActor == null then
                builtins.deepSeq (warn "[actors-system-cycle] unknown-msg-type actor=${m.to} type=${m.type}" null) (
                  onError (s // { queue = rest; }) {
                    kind = "unknown-msg-type";
                    actor = m.to;
                    type = m.type;
                  }
                )
              else if parsedForActor ? left then
                onError (s // { queue = rest; }) {
                  kind = "bad-actor-message";
                  actor = m.to;
                  type = m.type;
                  parse = parsedForActor.left;
                  input = m;
                }
              else
                let
                  out = actor.step m.to actor parsedForActor.right;
                  s1 = s // {
                    queue = rest;
                    actors = s.actors // {
                      ${"${m.to}"} = actor // {
                        state = out.state;
                      };
                    };
                    events = s.events ++ out.events;
                  };
                in
                builtins.foldl' (acc: c: applyCommand m.to acc c) s1 out.commands;
    in
    {
      inherit stepOne onError;
    };

  supervisor-c =
    { state, stepOne }:
    {
      state = state.map stepOne;
    };

  runtime-c =
    {
      tick-s,
      startState,
      stepOne,
    }:
    let
      state0-s = ned.st startState;
      step-c =
        { state }:
        {
          state = state.map stepOne;
        };
      state-s = tick-s.scanl (
        s: _tick: builtins.head ((step-c { state = ned.st s; }).state.toList)
      ) startState;
    in
    {
      state-s = state-s;
      state0-s = state0-s;
    };

  run =
    {
      actors,
      queue ? [ ],
      events ? [ ],
      mode ? "lenient",
      includeStates ? false,
    }:
    let
      bootMsgs = map (id: {
        to = id;
        from = "system";
        type = "$sys.boot";
        payload = { };
      }) (builtins.attrNames actors);
      start = {
        inherit actors events;
        queue = queue ++ bootMsgs;
        errors = [ ];
        halted = false;
      };

      core = runtimeCore {
        inherit
          actors
          queue
          events
          mode
          ;
      };
      inherit (core) stepOne;

      stepLimit = 256;
      tick-s = ned.st.fromList (builtins.genList (i: i) stepLimit);

      statesRawAll = if includeStates then (tick-s.scanl (s: _tick: stepOne s) start).toList else [ ];

      trim =
        xs:
        let
          go =
            i:
            if i + 1 >= builtins.length xs then
              i
            else
              let
                a = builtins.elemAt xs i;
                b = builtins.elemAt xs (i + 1);
              in
              if (a.queue == [ ] || (a.halted or false)) && a == b then i else go (i + 1);
          end = go 0;
        in
        builtins.genList (i: builtins.elemAt xs i) (end + 1);

      advance =
        n: s: if n <= 0 || s.queue == [ ] || (s.halted or false) then s else advance (n - 1) (stepOne s);

      statesRaw = if includeStates then trim statesRawAll else [ ];
      finalRaw =
        if includeStates then
          builtins.elemAt statesRaw ((builtins.length statesRaw) - 1)
        else
          advance stepLimit start;
    in
    {
      states = if includeStates then map stripFns statesRaw else [ ];
      final = stripFns finalRaw;
    };
in
{
  inherit
    run
    mkActor
    cmd
    msg
    mailbox-d
    supervisor-c
    runtime-c
    ;
}
