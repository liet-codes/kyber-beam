defmodule Kyber.Web.Plugs.RawBodyCache do
  @moduledoc """
  Custom body reader for `Plug.Parsers` that caches the raw request body in
  `conn.private[:raw_body]` before the parser consumes it.

  Required for webhook signature validation (e.g. `FamiliardController`), which
  needs the original unmodified bytes to recompute the HMAC against the
  `x-familiard-signature` header.

  ## Usage

  Configure as the `:body_reader` in `Plug.Parsers` (endpoint or pipeline):

      plug Plug.Parsers,
        parsers: [:json],
        json_decoder: Jason,
        body_reader: {Kyber.Web.Plugs.RawBodyCache, :read_body, []}
  """

  @doc """
  Reads the request body and caches it as `conn.private[:raw_body]`.

  Implements the `{m, f, a}` body reader interface expected by `Plug.Parsers`.
  `opts` are the standard `Plug.Conn.read_body/2` options.
  """
  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()}
          | {:more, binary(), Plug.Conn.t()}
          | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        conn = Plug.Conn.put_private(conn, :raw_body, body)
        {:ok, body, conn}

      {:more, partial, conn} ->
        # Body exceeds read_length — cache what we got (sufficient for HMAC)
        existing = conn.private[:raw_body] || ""
        conn = Plug.Conn.put_private(conn, :raw_body, existing <> partial)
        {:more, partial, conn}

      other ->
        other
    end
  end
end
