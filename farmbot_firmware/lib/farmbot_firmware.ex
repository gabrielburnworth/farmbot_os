defmodule FarmbotFirmware do
  @moduledoc """
  Firmware wrapper for interacting with Farmbot-Arduino-Firmware.
  This GenServer is expected to be a pretty simple state machine
  with no side effects to anything in the rest of the Farmbot application.
  Side effects should be implemented using a callback/pubsub system. This
  allows for indpendent testing.

  Functionality that is needed to boot the firmware:
    * parameters - Keyword list of {param_atom, float}

  Side affects that should be handled
    * position reports
    * end stop reports
    * calibration reports
    * busy reports

  # State machine
  The firmware starts in a `:transport_boot` state, moving to `:boot`. It then
  loads all parameters writes all parameters, and goes to idle if all params
  were loaded successfully.

  State machine flows go as follows:
  ## Boot
      :transport_boot
      |> :boot
      |> :no_config
      |> :configuration
      |> :idle

  ## Idle
      :idle
      |> :begin
      |> :busy
      |> :error | :invalid | :success

  # Constraints and Exceptions
  Commands will be queued as they received with some exceptions:
  * if a command is currently executing (state is not `:idle`),
    proceding commands will be queued in the order they are received.
  * the `:emergency_lock` and `:emergency_unlock` commands go to the front
    of the command queue and are started immediately.
  * if a `report_emergency_lock` message is received at any point during a
    commands execution, that command is considered an error.
    (this does not apply to `:boot` state, since `:parameter_write`
     is accepted while the firmware is locked.)
  * all reports outside of control flow reports (:begin, :error, :invalid,
    :success) will be discarded while in `:boot` state. This means while
    boot, position updates, end stop updates etc are ignored.

  # Transports
  GCODES should be exchanged in the following format:
      {tag, {command, args}}
  * `tag` - binary integer. This is translated to the `Q` parameter.
  * `command` - either a `RXX`, `FXX`, or `GXX` code.
  * `args` - a list of arguments to be processed.

  For example a report might look like:
      {"123", {:report_some_information, [h: 10.00, u: 90.10]}}
  and a command might look like:
      {"555", {:fire_laser, [w: 100.00]}}
  Numbers should be floats when possible. An Exeption to this is `:report_end_stops`
  where there is only two values: `1` or `0`.

  See the `GCODE` module for more information on available implemented GCODES.
  a `Transport` should be a process that implements standard `GenServer`
  behaviour.

  Upon `init/1` the args passed in should be a Keyword list required to configure
  the transport such as a serial device, etc. `args` will also contain a
  `:handle_gcode` function that should be called everytime a GCODE is received.

      Keyword.fetch!(args, :handle_gcode).({"999", {:report_software_version, ["Just a test!"]}})

  a transport should also implement a `handle_call` clause like:

      def handle_call({"166", {:parameter_write, [some_param: 100.00]}}, _from, state)

  and reply with `:ok | {:error, term()}`

  # VCR

  This server can save all the input and output gcodes to a text file for
  further external analysis or playback later.

  ## Using VCR mode

  The server can be started in VCR mode by doing:

      FarmbotFirmware.start_link([transport: FarmbotFirmware.StubTransport, vcr_path: "/tmp/vcr.txt"], [])

  or can be started at runtime:

      FarmbotFirmware.enter_vcr_mode(firmware_server, "/tmp/vcr.txt")

  in either case the VCR recording needs to be stopped:

      FarmbotFirmware.exit_vcr_mode(firmware_server)

  VCRs can later be played back:

      FarmbotFirmware.VCR.playback!("/tmp/vcr.txt")
  """
  use GenServer
  require Logger

  alias FarmbotFirmware, as: State
  alias FarmbotFirmware.{GCODE, Command, Request}

  @transport_init_error_retry_ms 5_000

  @type status ::
          :transport_boot
          | :boot
          | :no_config
          | :configuration
          | :idle
          | :emergency_lock

  defstruct [
    :transport,
    :transport_pid,
    :transport_ref,
    :transport_args,
    :side_effects,
    :status,
    :tag,
    :configuration_queue,
    :command_queue,
    :caller_pid,
    :current,
    :vcr_fd,
    :reset,
    :reset_pid
  ]

  @type state :: %State{
          transport: module(),
          transport_pid: nil | pid(),
          transport_ref: nil | reference(),
          transport_args: Keyword.t(),
          side_effects: nil | module(),
          status: status(),
          tag: GCODE.tag(),
          configuration_queue: [{GCODE.kind(), GCODE.args()}],
          command_queue: [{pid(), GCODE.t()}],
          caller_pid: nil | pid,
          current: nil | GCODE.t(),
          vcr_fd: nil | File.io_device(),
          reset: module(),
          reset_pid: nil | pid()
        }

  @doc """
  Command the firmware to do something. Takes a `{tag, {command, args}}`
  GCODE. This command will be queued if there is already a command
  executing. (this does not apply to `:emergency_lock` and `:emergency_unlock`)

  ## Response/Control Flow
  When executed, `command` will block until one of the following respones
  are received:
    * `{:report_success, []}` -> `:ok`
    * `{:report_invalid, []}` -> `{:error, :invalid_command}`
    * `{:report_error, []}` -> `{:error, :firmware_error}`
    * `{:report_emergency_lock, []}` -> `{:error, :emergency_lock}`

  If the firmware is in any of the following states:
    * `:boot`
    * `:no_config`
    * `:configuration`
  `command` will fail with `{:error, state}`
  """
  defdelegate command(server \\ __MODULE__, code), to: Command

  @doc """
  Request data from the firmware.
  Valid requests are of kind:

      :parameter_read
      :status_read
      :pin_read
      :end_stops_read
      :position_read
      :software_version_read

  Will return `{:ok, {tag, {:report_*, args}}}` on success
  or `{:error, term()}` on error.
  """
  defdelegate request(server \\ __MODULE__, code), to: Request

  @doc """
  Close the transport, putting the Firmware State Machine back into
  the `:transport_boot` state.
  """
  def close_transport(server \\ __MODULE__) do
    _ = command(server, {nil, {:command_emergency_lock, []}})
    GenServer.call(server, :close_transport)
  end

  @doc """
  Opens the transport,
  """
  def open_transport(server \\ __MODULE__, module, args) do
    GenServer.call(server, {:open_transport, module, args})
  end

  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

  @doc """
  Sets the Firmware server to record input and output GCODES
  to a pair of text files.
  """
  def enter_vcr_mode(server \\ __MODULE__, tape_path) do
    GenServer.call(server, {:enter_vcr_mode, tape_path})
  end

  @doc """
  Sets the Firmware server to stop recording input and output
  GCODES.
  """
  def exit_vcr_mode(server \\ __MODULE__) do
    GenServer.cast(server, :exit_vcr_mode)
  end

  @doc """
  Starting the Firmware server requires at least:
  * `:transport` - a module implementing the Transport GenServer behaviour.
    See the `Transports` section of moduledoc.

  Every other arg passed in will be passed directly to the `:transport` module's
  `init/1` function.
  """
  def start_link(args, opts \\ [name: __MODULE__]) do
    GenServer.start_link(__MODULE__, args, opts)
  end

  def init(args) do
    global = Application.get_env(:farmbot_firmware, __MODULE__, [])
    args = Keyword.merge(args, global)
    transport = Keyword.fetch!(args, :transport)
    side_effects = Keyword.get(args, :side_effects)
    # This is probably the cause of
    # https://github.com/FarmBot/farmbot_os/issues/1111
    # FarmbotFirmware.NullReset (RPi3? Safe default?)
    #  -OR-
    # FarmbotOS.Platform.Target.FirmwareReset.GPIO (RPi0, RPi)
    #  -OR-
    # Use Application.get_env to find target?
    # probably?
    reset = Keyword.get(args, :reset) || FarmbotFirmware.NullReset

    vcr_fd =
      case Keyword.get(args, :vcr_path) do
        nil ->
          nil

        tape_path ->
          {:ok, vcr_fd} = File.open(tape_path, [:binary, :append, :exclusive, :write])

          vcr_fd
      end

    # Add an anon function that transport implementations should call.
    fw = self()
    fun = fn {_, _} = code -> GenServer.cast(fw, code) end
    transport_args = Keyword.put(args, :handle_gcode, fun)

    state = %State{
      transport_pid: nil,
      transport_ref: nil,
      transport: transport,
      transport_args: transport_args,
      side_effects: side_effects,
      status: :transport_boot,
      reset: reset,
      reset_pid: nil,
      command_queue: [],
      configuration_queue: [],
      vcr_fd: vcr_fd
    }

    send(self(), :timeout)
    {:ok, state}
  end

  def terminate(reason, state) do
    for {pid, _code} <- state.command_queue, do: send(pid, reason)

    state.transport_pid &&
      Process.alive?(state.transport_pid) &&
      GenServer.stop(state.transport_pid)
  end

  def handle_info(:timeout, %{status: :transport_boot, reset_pid: nil} = state) do
    case GenServer.start_link(state.reset, state.transport_args,
           name: state.reset
         ) do
      {:ok, pid} ->
        Logger.debug(
          "Firmware reset #{state.reset} started. #{
            inspect(state.transport_args)
          }"
        )

        {:noreply, %{state | reset_pid: pid}}

      # TODO(Rick): I have no idea what's going on here.
      {:error, {:already_started, pid}} ->
        Logger.debug(
          "Firmware reset complete. #{inspect(state.transport_args)}"
        )

        {:noreply, %{state | reset_pid: pid}}

      error ->
        Logger.error("Error starting Firmware Reset: #{inspect(error)}")
        Process.send_after(self(), :timeout, @transport_init_error_retry_ms)
        {:noreply, state}
    end
  end

  # This will be the first message received right after `init/1`
  # It should try to open a transport every `transport_init_error_retry_ms`
  # until success.
  # TODO(Connor) maybe make this timer back off over time.
  def handle_info(:timeout, %{status: :transport_boot} = state) do
    case GenServer.start_link(state.transport, state.transport_args) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.debug(
          "Firmware Transport #{state.transport} started. #{
            inspect(state.transport_args)
          }"
        )

        state = goto(%{state | transport_pid: pid, transport_ref: ref}, :boot)
        {:noreply, state}

      error ->
        Logger.error("Error starting Firmware: #{inspect(error)}")
        Process.send_after(self(), :timeout, @transport_init_error_retry_ms)
        {:noreply, state}
    end
  end

  # @spec handle_info(:timeout, state) :: {:noreply, state}
  def handle_info(
        :timeout,
        %{
          command_queue: [
            {pid, {tag, {:command_emergency_lock, []} = code}} | _
          ]
        } = state
      ) do
    case GenServer.call(state.transport_pid, {tag, code}) do
      :ok ->
        new_state = %{
          state
          | tag: tag,
            current: code,
            command_queue: [],
            caller_pid: pid
        }

        _ = side_effects(new_state, :handle_output_gcode, [{state.tag, code}])
        _ = vcr_write(state, :out, {state.tag, code})

        {:noreply, new_state}

      error ->
        {:stop, error, state}
    end
  end

  def handle_info(:timeout, %{configuration_queue: [code | rest]} = state) do
    # Logger.debug("Starting next configuration code: #{inspect(code)}")

    case GenServer.call(state.transport_pid, {state.tag, code}) do
      :ok ->
        new_state = %{state | current: code, configuration_queue: rest}
        _ = side_effects(new_state, :handle_output_gcode, [{state.tag, code}])
        _ = vcr_write(state, :out, {state.tag, code})
        {:noreply, new_state}

      error ->
        {:stop, error, state}
    end
  end

  def handle_info(:timeout, %{current: c} = state) when is_tuple(c) do
    if state.caller_pid,
      do: send(state.caller_pid, {state.tag, {:report_busy, []}})

    for {pid, _code} <- state.command_queue,
        do: send(pid, {state.tag, {:report_busy, []}})

    # Logger.debug "Got checkup message when current command still executing"
    {:noreply, state}
  end

  def handle_info(
        :timeout,
        %{command_queue: [{pid, {tag, code}} | rest]} = state
      ) do
    for {pid, _code} <- state.command_queue,
        do: send(pid, {state.tag, {:report_busy, []}})

    case GenServer.call(state.transport_pid, {tag, code}) do
      :ok ->
        new_state = %{
          state
          | tag: tag,
            current: code,
            command_queue: rest,
            caller_pid: pid
        }

        _ = side_effects(new_state, :handle_output_gcode, [{state.tag, code}])
        _ = vcr_write(state, :out, {state.tag, code})
        for {pid, _code} <- rest, do: send(pid, {state.tag, {:report_busy, []}})

        {:noreply, new_state}

      error ->
        {:stop, error, state}
    end
  end

  def handle_info(:timeout, %{configuration_queue: []} = state) do
    {:noreply, state}
  end

  def handle_call(:reset, _from, state) do
    r = state.reset.reset()
    {:reply, r, state}
  end

  # Closing the transport will purge the buffer of queued commands in both
  # the `configuration_queue` and in the `command_queue`.
  def handle_call(:close_transport, _from, %{status: s} = state)
      when s != :transport_boot do
    true = Process.demonitor(state.transport_ref)
    :ok = GenServer.stop(state.transport_pid, :normal)

    next_state =
      goto(
        %{
          state
          | transport_pid: nil,
            transport_ref: nil,
            status: :transport_boot,
            command_queue: [],
            configuration_queue: []
        },
        :transport_boot
      )

    {:reply, :ok, next_state}
  end

  def handle_call(:close_transport, _, %{status: s} = state) do
    {:reply, {:error, s}, state}
  end

  def handle_call({:open_transport, module, args}, _from, %{status: s} = state)
      when s == :transport_boot do
    # Add an anon function that transport implementations should call.
    fw = self()
    fun = fn {_, _} = code -> GenServer.cast(fw, code) end

    transport_args =
      state.transport_args
      |> Keyword.merge(args)
      |> Keyword.merge(handle_gcode: fun)

    next_state = %{state | transport: module, transport_args: transport_args}

    send(self(), :timeout)
    {:reply, :ok, next_state}
  end

  def handle_call(
        {:open_transport, _module, _args},
        _from,
        %{status: s} = state
      ) do
    {:reply, {:error, s}, state}
  end

  def handle_call({:enter_vcr_mode, tape_path}, _from, state) do
    with {:ok, vcr_fd} <-
           File.open(tape_path, [:binary, :append, :exclusive, :write]) do
      {:reply, :ok, %{state | vcr_fd: vcr_fd}}
    else
      error ->
        {:reply, error, state}
    end
  end

  def handle_call({_tag, _code} = gcode, from, state) do
    handle_command(gcode, from, state)
  end

  @doc false
  @spec handle_command(GCODE.t(), GenServer.from(), state()) ::
          {:reply, term(), state()}

  # EmergencyLock should be ran immediately
  def handle_command(
        {tag, {:command_emergency_lock, []}} = code,
        {pid, _ref},
        state
      ) do
    if state.caller_pid,
      do: send(state.caller_pid, {state.tag, {:report_emergency_lock, []}})

    for {pid, _code} <- state.command_queue,
        do: send(pid, {state.tag, {:report_emergency_lock, []}})

    send(self(), :timeout)

    {:reply, {:ok, tag},
     %{state | command_queue: [{pid, code}], configuration_queue: []}}
  end

  # EmergencyUnLock should be ran immediately
  def handle_command(
        {tag, {:command_emergency_unlock, []}} = code,
        {pid, _ref},
        state
      ) do
    send(self(), :timeout)

    {:reply, {:ok, tag},
     %{state | command_queue: [{pid, code}], configuration_queue: []}}
  end

  # If not in an acceptable state, return an error immediately.
  def handle_command(_, _, %{status: s} = state)
      when s in [:transport_boot, :boot, :no_config, :configuration] do
    {:reply, {:error, s}, state}
  end

  def handle_command({tag, {_, _}} = code, {pid, _ref}, state) do
    new_state = %{state | command_queue: state.command_queue ++ [{pid, code}]}

    case {new_state.status, state.current} do
      {:idle, nil} ->
        send(self(), :timeout)
        {:reply, {:ok, tag}, new_state}

      # Don't do any flow control if state is emergency_lock.
      # This allows a transport to decide
      # if a command should be blocked or not.
      {:emergency_lock, _} ->
        send(self(), :timeout)
        {:reply, {:ok, tag}, new_state}

      _unknown ->
        {:reply, {:ok, tag}, new_state}
    end
  end

  def handle_cast(:exit_vcr_mode, state) do
    state.vcr_fd && File.close(state.vcr_fd)
    {:noreply, %{state | vcr_fd: nil}}
  end

  # Extracts tag
  def handle_cast({tag, {_, _} = code}, state) do
    _ = side_effects(state, :handle_input_gcode, [{tag, code}])
    _ = vcr_write(state, :in, {tag, code})
    handle_report(code, %{state | tag: tag})
  end

  @doc false
  @spec handle_report({GCODE.report_kind(), GCODE.args()}, state) ::
          {:noreply, state()}
  def handle_report({:report_emergency_lock, []} = code, state) do
    Logger.info("Emergency lock")
    if state.caller_pid, do: send(state.caller_pid, {state.tag, code})
    for {pid, _code} <- state.command_queue, do: send(pid, code)

    send(self(), :timeout)
    {:noreply, goto(%{state | current: nil, caller_pid: nil}, :emergency_lock)}
  end

  # "ARDUINO STARTUP COMPLETE" => goto(:boot, :no_config)
  def handle_report(
        {:unknown, [_, "ARDUINO", "STARTUP", "COMPLETE"]},
        %{status: :boot} = state
      ) do
    Logger.info("ARDUINO STARTUP COMPLETE (text) transport=#{state.transport}")
    handle_report({:report_no_config, []}, state)
  end

  def handle_report(
        {:report_idle, []},
        %{status: :boot} = state
      ) do
    Logger.info("ARDUINO STARTUP COMPLETE (idle) transport=#{state.transport}")
    handle_report({:report_no_config, []}, state)
  end

  def handle_report(
        {:report_debug_message, ["ARDUINO STARTUP COMPLETE"]},
        %{status: :boot} = state
      ) do
    Logger.info("ARDUINO STARTUP COMPLETE (r99) transport=#{state.transport}")
    handle_report({:report_no_config, []}, state)
  end

  # report_no_config => goto(_, :no_config)
  def handle_report({:report_no_config, []}, %{status: _} = state) do
    Logger.warn(":report_no_config received")
    tag = state.tag || "0"
    loaded_params = side_effects(state, :load_params, []) || []

    param_commands =
      Enum.reduce(loaded_params, [], fn {param, val}, acc ->
        if val, do: acc ++ [{:parameter_write, [{param, val}]}], else: acc
      end)

    to_process =
      [{:software_version_read, []} | param_commands] ++
        [
          {:parameter_write, [{:param_use_eeprom, 0.0}]},
          {:parameter_write, [{:param_config_ok, 1.0}]},
          {:parameter_read_all, []}
        ]

    to_process =
      if loaded_params[:movement_home_at_boot_z] == 1,
        do: to_process ++ [{:command_movement_find_home, [:z]}],
        else: to_process

    to_process =
      if loaded_params[:movement_home_at_boot_y] == 1,
        do: to_process ++ [{:command_movement_find_home, [:y]}],
        else: to_process

    to_process =
      if loaded_params[:movement_home_at_boot_x] == 1,
        do: to_process ++ [{:command_movement_find_home, [:x]}],
        else: to_process

    send(self(), :timeout)

    {:noreply,
     goto(%{state | tag: tag, configuration_queue: to_process}, :configuration)}
  end

  def handle_report({:report_debug_message, msg}, state) do
    side_effects(state, :handle_debug_message, [msg])
    {:noreply, state}
  end

  def handle_report(report, %{status: :boot} = state) do
    Logger.debug(["still in state: :boot ", inspect(report)])
    {:noreply, state}
  end

  # an idle report while there is a current command running
  # should not count.
  def handle_report({:report_idle, []}, %{current: c} = state)
      when is_tuple(c) do
    if state.caller_pid,
      do: send(state.caller_pid, {state.tag, {:report_busy, []}})

    for {pid, _code} <- state.command_queue,
        do: send(pid, {state.tag, {:report_busy, []}})

    {:noreply, state}
  end

  # report_idle => goto(_, :idle)
  def handle_report({:report_idle, []}, %{status: _} = state) do
    for {pid, _code} <- state.command_queue,
        do: send(pid, {state.tag, {:report_busy, []}})

    side_effects(state, :handle_busy, [false])
    side_effects(state, :handle_idle, [true])
    send(self(), :timeout)
    {:noreply, goto(%{state | caller_pid: nil, current: nil}, :idle)}
  end

  def handle_report({:report_begin, []} = code, state) do
    if state.caller_pid, do: send(state.caller_pid, {state.tag, code})

    for {pid, _code} <- state.command_queue,
        do: send(pid, {state.tag, {:report_busy, []}})

    {:noreply, goto(state, :begin)}
  end

  def handle_report({:report_success, []} = code, state) do
    if state.caller_pid, do: send(state.caller_pid, {state.tag, code})

    for {pid, _code} <- state.command_queue,
        do: send(pid, {state.tag, {:report_busy, []}})

    new_state = %{state | current: nil, caller_pid: nil}
    side_effects(state, :handle_busy, [false])
    send(self(), :timeout)
    {:noreply, goto(new_state, :idle)}
  end

  def handle_report({:report_busy, []} = code, state) do
    if state.caller_pid, do: send(state.caller_pid, {state.tag, code})

    for {pid, _code} <- state.command_queue,
        do: send(pid, {state.tag, {:report_busy, []}})

    side_effects(state, :handle_busy, [true])
    {:noreply, goto(state, :busy)}
  end

  def handle_report(
        {:report_error, _} = code,
        %{status: :configuration} = state
      ) do
    if state.caller_pid, do: send(state.caller_pid, {state.tag, code})

    for {pid, _code} <- state.command_queue,
        do: send(pid, {state.tag, {:report_busy, []}})

    side_effects(state, :handle_busy, [false])
    {:stop, {:error, state.current}, state}
  end

  def handle_report({:report_error, _} = code, state) do
    if state.caller_pid, do: send(state.caller_pid, {state.tag, code})

    for {pid, _code} <- state.command_queue,
        do: send(pid, {state.tag, {:report_busy, []}})

    side_effects(state, :handle_busy, [false])
    send(self(), :timeout)
    {:noreply, %{state | caller_pid: nil, current: nil}}
  end

  def handle_report(
        {:report_invalid, []} = code,
        %{status: :configuration} = state
      ) do
    if state.caller_pid, do: send(state.caller_pid, {state.tag, code})

    for {pid, _code} <- state.command_queue,
        do: send(pid, {state.tag, {:report_busy, []}})

    {:stop, {:error, state.current}, state}
  end

  def handle_report({:report_invalid, []} = code, state) do
    if state.caller_pid, do: send(state.caller_pid, {state.tag, code})

    for {pid, _code} <- state.command_queue,
        do: send(pid, {state.tag, {:report_busy, []}})

    send(self(), :timeout)
    {:noreply, %{state | caller_pid: nil, current: nil}}
  end

  def handle_report(
        {:report_retry, []} = code,
        %{status: :configuration} = state
      ) do
    Logger.warn("Retrying configuration command: #{inspect(code)}")
    {:noreply, state}
  end

  def handle_report({:report_retry, []} = code, state) do
    if state.caller_pid, do: send(state.caller_pid, {state.tag, code})

    for {pid, _code} <- state.command_queue,
        do: send(pid, {state.tag, {:report_busy, []}})

    {:noreply, state}
  end

  def handle_report({:report_parameter_value, param} = code, state) do
    if state.caller_pid, do: send(state.caller_pid, {state.tag, code})

    for {pid, _code} <- state.command_queue,
        do: send(pid, {state.tag, {:report_busy, []}})

    side_effects(state, :handle_parameter_value, [param])
    {:noreply, state}
  end

  def handle_report({:report_calibration_parameter_value, param} = _code, state) do
    to_process = [{:parameter_write, param}]
    side_effects(state, :handle_parameter_value, [param])
    side_effects(state, :handle_parameter_calibration_value, [param])
    send(self(), :timeout)

    {:noreply,
     goto(
       %{state | tag: state.tag, configuration_queue: to_process},
       :configuration
     )}
  end

  # report_parameters_complete => goto(:configuration, :idle)
  def handle_report(
        {:report_parameters_complete, []},
        %{status: status} = state
      )
      when status in [:begin, :configuration] do
    {:noreply, goto(state, :idle)}
  end

  def handle_report(_, %{status: :no_config} = state) do
    {:noreply, state}
  end

  def handle_report({:report_position, position} = code, state) do
    if state.caller_pid, do: send(state.caller_pid, {state.tag, code})

    for {pid, _code} <- state.command_queue,
        do: send(pid, {state.tag, {:report_busy, []}})

    side_effects(state, :handle_position, [position])
    {:noreply, state}
  end

  def handle_report({:report_load, load} = code, state) do
    if state.caller_pid, do: send(state.caller_pid, {state.tag, code})

    for {pid, _code} <- state.command_queue,
        do: send(pid, {state.tag, {:report_busy, []}})

    side_effects(state, :handle_load, [load])
    {:noreply, state}
  end

  def handle_report({:report_axis_state, axis_state} = code, state) do
    if state.caller_pid, do: send(state.caller_pid, {state.tag, code})

    for {pid, _code} <- state.command_queue,
        do: send(pid, {state.tag, {:report_busy, []}})

    side_effects(state, :handle_axis_state, [axis_state])
    {:noreply, state}
  end

  def handle_report({:report_axis_timeout, [axis]} = code, state) do
    if state.caller_pid, do: send(state.caller_pid, {state.tag, code})

    for {pid, _code} <- state.command_queue,
        do: send(pid, {state.tag, {:report_busy, []}})

    side_effects(state, :handle_axis_timeout, [axis])
    {:noreply, state}
  end

  def handle_report(
        {:report_calibration_state, calibration_state} = code,
        state
      ) do
    if state.caller_pid, do: send(state.caller_pid, {state.tag, code})

    for {pid, _code} <- state.command_queue,
        do: send(pid, {state.tag, {:report_busy, []}})

    side_effects(state, :handle_calibration_state, [calibration_state])
    {:noreply, state}
  end

  def handle_report({:report_home_complete, axis} = code, state) do
    if state.caller_pid, do: send(state.caller_pid, {state.tag, code})

    for {pid, _code} <- state.command_queue,
        do: send(pid, {state.tag, {:report_busy, []}})

    side_effects(state, :handle_home_complete, axis)
    {:noreply, state}
  end

  def handle_report({:report_position_change, position} = code, state) do
    if state.caller_pid, do: send(state.caller_pid, {state.tag, code})

    for {pid, _code} <- state.command_queue,
        do: send(pid, {state.tag, {:report_busy, []}})

    side_effects(state, :handle_position_change, [position])
    {:noreply, state}
  end

  def handle_report({:report_encoders_scaled, encoders} = code, state) do
    if state.caller_pid, do: send(state.caller_pid, {state.tag, code})

    for {pid, _code} <- state.command_queue,
        do: send(pid, {state.tag, {:report_busy, []}})

    side_effects(state, :handle_encoders_scaled, [encoders])
    {:noreply, state}
  end

  def handle_report({:report_encoders_raw, encoders} = code, state) do
    if state.caller_pid, do: send(state.caller_pid, {state.tag, code})

    for {pid, _code} <- state.command_queue,
        do: send(pid, {state.tag, {:report_busy, []}})

    side_effects(state, :handle_encoders_raw, [encoders])
    {:noreply, state}
  end

  def handle_report({:report_end_stops, end_stops} = code, state) do
    if state.caller_pid, do: send(state.caller_pid, {state.tag, code})

    for {pid, _code} <- state.command_queue,
        do: send(pid, {state.tag, {:report_busy, []}})

    side_effects(state, :handle_end_stops, [end_stops])
    {:noreply, state}
  end

  def handle_report({:report_pin_value, value} = code, state) do
    if state.caller_pid, do: send(state.caller_pid, {state.tag, code})

    for {pid, _code} <- state.command_queue,
        do: send(pid, {state.tag, {:report_busy, []}})

    side_effects(state, :handle_pin_value, [value])
    {:noreply, state}
  end

  def handle_report({:report_software_version, version} = code, state) do
    if state.caller_pid, do: send(state.caller_pid, {state.tag, code})

    for {pid, _code} <- state.command_queue,
        do: send(pid, {state.tag, {:report_busy, []}})

    side_effects(state, :handle_software_version, [version])
    {:noreply, state}
  end

  # NOOP
  def handle_report({:report_echo, _}, state), do: {:noreply, state}

  def handle_report({_kind, _args} = code, state) do
    Logger.warn("unknown code for #{state.status}: #{inspect(code)}")
    {:noreply, state}
  end

  @spec goto(state(), status()) :: state()
  defp goto(%{status: old} = state, new) do
    new_state = %{state | status: new}

    cond do
      old != new && new == :emergency_lock ->
        side_effects(new_state, :handle_emergency_lock, [])

      old != new && old == :emergency_lock ->
        side_effects(new_state, :handle_emergency_unlock, [])

      # Boot up emergency unlock
      old == :boot && new != :emergency_lock ->
        side_effects(new_state, :handle_emergency_unlock, [])

      # start of a command.
      old == :idle && new == :begin ->
        :ok

      # command processing
      old == :begin && new == :busy ->
        :ok

      # command completion
      old == :begin && new == :idle ->
        :ok

      # command completion
      old == :busy && new == :idle ->
        :ok

      old == new ->
        :ok

      true ->
        Logger.debug("firmware state change: #{old} => #{new}")
    end

    new_state
  end

  @spec side_effects(state, atom, GCODE.args()) :: any()
  defp side_effects(%{side_effects: nil}, _function, _args), do: nil

  defp side_effects(%{side_effects: m}, function, args),
    do: apply(m, function, args)

  @spec vcr_write(state, :in | :out, GCODE.t()) :: :ok
  defp vcr_write(%{vcr_fd: nil}, _direction, _code), do: :ok

  defp vcr_write(state, :in, code), do: vcr_write(state, "<", code)

  defp vcr_write(state, :out, code), do: vcr_write(state, "\n>", code)

  defp vcr_write(state, direction, code) do
    data = GCODE.encode(code)
    time = :os.system_time(:second)

    current_data =
      if state.current do
        GCODE.encode({state.tag, state.current})
      else
        "nil"
      end

    state_data = "#{state.status} | #{current_data} | #{inspect(state.caller_pid)}"

    IO.write(
      state.vcr_fd,
      direction <> " #{time} " <> data <> " state=" <> state_data <> "\n"
    )
  end
end
