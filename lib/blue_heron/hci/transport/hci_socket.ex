# SPDX-FileCopyrightText: 2026 Marc Lainez
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule BlueHeron.HCI.Transport.HCISocket do
  @moduledoc """
  HCI transport over a Linux Bluetooth socket bound to the user channel.

  Use this when the kernel already drives the controller (for example
  through `btqcomsmd`, `btusb` or `hci_uart`) and exposes it as `hciN`,
  rather than handing BlueHeron a raw UART. The user channel gives
  BlueHeron exclusive access to the controller: the kernel's own Bluetooth
  stack and BlueZ stay out of the way while the socket is open.

  The device must be down when the socket binds, so nothing else (such as
  `bluetoothd`) may have powered it on. Binding needs `CAP_NET_ADMIN`.

  Options:

    * `:device` - index of the HCI device, `0` for `hci0` (default `0`)
  """

  use GenServer
  require Logger

  @af_bluetooth 31
  @btproto_hci 1
  @hci_channel_user 1

  @hci_command_packet 0x01
  @hci_acl_packet 0x02

  @doc """
  Open and bind the socket, then start the process that owns it.

  Binding happens before the process starts so that a missing or busy
  device is returned as `{:error, reason}` for `BlueHeron.HCI.Transport`
  to retry, instead of crashing the linked caller.
  """
  def start_link(args) do
    device = Keyword.get(args, :device, 0)

    with {:ok, socket} <- open(device),
         {:ok, pid} <- GenServer.start_link(__MODULE__, {socket, device}) do
      :ok = :socket.setopt(socket, {:otp, :controlling_process}, pid)
      send(pid, :recv)
      {:ok, pid}
    end
  end

  @doc "Send binary HCI data"
  @spec send_command(GenServer.server(), binary()) :: :ok | {:error, term()}
  def send_command(pid, command) when is_binary(command) do
    GenServer.call(pid, {:send, [<<@hci_command_packet::8>>, command]})
  end

  @doc "Send binary ACL data"
  @spec send_acl(GenServer.server(), binary()) :: :ok | {:error, term()}
  def send_acl(pid, acl) when is_binary(acl) do
    GenServer.call(pid, {:send, [<<@hci_acl_packet::8>>, acl]})
  end

  @doc "Flush buffers (a no-op: every packet is its own datagram)"
  @spec flush(GenServer.server()) :: :ok
  def flush(_pid), do: :ok

  defp open(device) do
    with {:ok, socket} <- :socket.open(@af_bluetooth, :raw, @btproto_hci) do
      # struct sockaddr_hci { sa_family_t family; u16 dev; u16 channel; }
      addr = %{family: @af_bluetooth, addr: <<device::little-16, @hci_channel_user::little-16>>}

      case :socket.bind(socket, addr) do
        :ok ->
          Logger.info("Opened hci#{device} user channel for HCI transport")
          {:ok, socket}

        {:error, reason} ->
          :socket.close(socket)
          Logger.error("Failed to bind hci#{device} user channel: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  ## Server Callbacks

  @impl GenServer
  def init({socket, device}) do
    {:ok, %{socket: socket, device: device}}
  end

  @impl GenServer
  def handle_call({:send, packet}, _from, state) do
    {:reply, :socket.send(state.socket, packet), state}
  end

  @impl GenServer
  def handle_info(:recv, state), do: recv(state)

  def handle_info({:"$socket", socket, :select, _info}, %{socket: socket} = state),
    do: recv(state)

  # Each recv returns one whole packet, starting with its HCI packet type.
  defp recv(state) do
    case :socket.recv(state.socket, 0, :nowait) do
      {:ok, packet} ->
        _ = BlueHeron.HCI.Transport.transport_data(packet)
        recv(state)

      {:select, _info} ->
        {:noreply, state}

      {:error, reason} ->
        {:stop, {:recv_failed, reason}, state}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    :socket.close(state.socket)
  end
end
