# @input  - Manual dated app business metrics and notes
# @output - Metrics snapshot records with nullable numeric fields
# @pos    - Business-loop schema for post-launch portfolio decisions
defmodule Afp.Factory.Metrics.MetricsSnapshot do
  use Afp.Factory.Schema

  alias Afp.Factory.JsonData

  schema "metrics_snapshots" do
    field :snapshot_date, :date
    field :downloads, :integer
    field :impressions, :integer
    field :product_page_views, :integer
    field :conversion_rate, :decimal
    field :revenue, :decimal
    field :trials, :integer
    field :subscriptions, :integer
    field :refunds, :integer
    field :rating, :decimal
    field :reviews_count, :integer
    field :crashes, :integer
    field :support_issues, :integer
    field :notes, :string
    field :payload, JsonData, default: %{}

    belongs_to :app, Afp.Factory.Portfolio.App

    timestamps()
  end

  def changeset(metrics_snapshot, attrs) do
    metrics_snapshot
    |> cast(attrs, [
      :app_id,
      :snapshot_date,
      :downloads,
      :impressions,
      :product_page_views,
      :conversion_rate,
      :revenue,
      :trials,
      :subscriptions,
      :refunds,
      :rating,
      :reviews_count,
      :crashes,
      :support_issues,
      :notes,
      :payload
    ])
    |> put_default_date()
    |> validate_required([:app_id, :snapshot_date])
    |> validate_number(:downloads, greater_than_or_equal_to: 0)
    |> validate_number(:impressions, greater_than_or_equal_to: 0)
    |> validate_number(:product_page_views, greater_than_or_equal_to: 0)
    |> validate_number(:trials, greater_than_or_equal_to: 0)
    |> validate_number(:subscriptions, greater_than_or_equal_to: 0)
    |> validate_number(:refunds, greater_than_or_equal_to: 0)
    |> validate_number(:reviews_count, greater_than_or_equal_to: 0)
    |> validate_number(:crashes, greater_than_or_equal_to: 0)
    |> validate_number(:support_issues, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:app_id)
  end

  defp put_default_date(changeset) do
    if get_field(changeset, :snapshot_date) do
      changeset
    else
      put_change(changeset, :snapshot_date, Date.utc_today())
    end
  end
end
