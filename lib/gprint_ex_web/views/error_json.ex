defmodule GprintExWeb.ErrorJSON do
  @moduledoc """
  JSON error responses.
  """

  def render("error.json", %{code: code, message: message}) do
    %{
      success: false,
      error: %{
        code: code,
        message: message
      }
    }
  end

  def render("404.json", _assigns) do
    %{
      success: false,
      error: %{
        code: "NOT_FOUND",
        message: "Resource not found"
      }
    }
  end

  def render("500.json", _assigns) do
    %{
      success: false,
      error: %{
        code: "INTERNAL_ERROR",
        message: "Internal server error"
      }
    }
  end

  def render("422.json", %{changeset: changeset}) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    %{
      success: false,
      error: %{
        code: "VALIDATION_ERROR",
        message: "Validation failed",
        details: errors
      }
    }
  end

  def render("validation_error.json", %{errors: errors}) do
    %{
      success: false,
      error: %{
        code: "VALIDATION_ERROR",
        message: "Validation failed",
        details: errors
      }
    }
  end
end
