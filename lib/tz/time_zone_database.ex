defmodule Tz.TimeZoneDatabase do
  @moduledoc false

  @behaviour Calendar.TimeZoneDatabase

  alias Tz.PeriodsProvider

  @compile {:inline, period_to_map: 1}

  @impl true
  # called by DateTime.shift_zone/3 and DateTime.add/4
  def time_zone_period_from_utc_iso_days(iso_days, time_zone) do
    with {:ok, periods} <- PeriodsProvider.periods(time_zone) do
      iso_days_to_gregorian_seconds(iso_days)
      |> find_period_for_secs(periods, :utc)
    end
  end

  @impl true
  # called by DateTime.from_naive/3
  def time_zone_periods_from_wall_datetime(naive_datetime, time_zone) do
    with {:ok, periods} <- PeriodsProvider.periods(time_zone) do
      naive_datetime_to_gregorian_seconds(naive_datetime)
      |> find_period_for_secs(periods, :wall)
    end
  end

  defp find_period_for_secs(secs, periods, time_modifier) do
    case do_find_period_for_secs(secs, periods, time_modifier) do
      {:max, utc_offset, rules_and_template} ->
        periods = generate_dynamic_periods(secs, utc_offset, rules_and_template)
        do_find_period_for_secs(secs, periods, time_modifier)

      result ->
        result
    end
  end

  defp do_find_period_for_secs(secs, periods, :utc) do
    case Enum.find(periods, fn {from, _, _, _} -> secs >= from end) do
      {_, period, _, nil} ->
        {:ok, period_to_map(period)}

      {_, {utc_off, _, _}, _, rules_and_template} ->
        {:max, utc_off, rules_and_template}

      nil ->
        {_, period, _, _} = List.last(periods)
        {:ok, period_to_map(period)}
    end
  end

  defp do_find_period_for_secs(secs, periods, :wall), do: find_period_for_wall_secs(secs, periods)

  # receives wall gregorian seconds (also referred as the 'given timestamp' in the comments below)
  # and the list of transitions
  defp find_period_for_wall_secs(_, [{0, period, _, _}]), do: {:ok, period_to_map(period)}

  defp find_period_for_wall_secs(secs, [
         {utc_secs, period = {utc_off, std_off, _}, prev_period = {prev_utc_off, prev_std_off, _},
          rules_and_template}
         | tail
       ]) do
    # utc_secs + utc_off + std_off = wall gregorian seconds
    if secs < utc_secs + utc_off + std_off do
      # the given timestamp occurs in a gap if it occurs between
      # the utc timestamp + the previous offset and
      # the utc timestamp + the offset (= this transition's wall time)
      if secs >= utc_secs + prev_utc_off + prev_std_off do
        {:gap,
         {period_to_map(prev_period),
          gregorian_seconds_to_naive_datetime(utc_secs + prev_utc_off + prev_std_off)},
         {period_to_map(period),
          gregorian_seconds_to_naive_datetime(utc_secs + utc_off + std_off)}}
      else
        # the given timestamp occurs before this transition and there is no gap with the previous period,
        # so continue iterating
        find_period_for_wall_secs(secs, tail)
      end
    else
      # the given timestamp occurs during two periods if it occurs between
      # the utc timestamp + the offset (= this transition's wall time) and
      # the utc timestamp + the previous offset
      if secs < utc_secs + prev_utc_off + prev_std_off do
        {:ambiguous, period_to_map(prev_period), period_to_map(period)}
      else
        # the given timestamp occurs after this transition's wall time, and there is no gap nor overlap
        case rules_and_template do
          nil ->
            {:ok, period_to_map(period)}

          _ ->
            {:max, utc_off, rules_and_template}
        end
      end
    end
  end

  defp period_to_map({utc_off, std_off, abbr}) do
    %{
      utc_offset: utc_off,
      std_offset: std_off,
      zone_abbr: abbr
    }
  end

  @doc false
  def generate_dynamic_periods(secs, utc_offset, {rule_name, format_time_zone_abbr}) do
    %{year: year} = gregorian_seconds_to_naive_datetime(secs)

    [rule1, rule2] = Tz.OngoingChangingRulesProvider.rules(rule_name)

    rule_records =
      Tz.IanaFileParser.denormalized_rule_data([
        Tz.IanaFileParser.change_rule_year(rule2, year - 1),
        Tz.IanaFileParser.change_rule_year(rule1, year - 1),
        Tz.IanaFileParser.change_rule_year(rule2, year),
        Tz.IanaFileParser.change_rule_year(rule1, year),
        Tz.IanaFileParser.change_rule_year(rule2, year + 1),
        Tz.IanaFileParser.change_rule_year(rule1, year + 1)
      ])

    zone_line = %{
      from: :min,
      to: :max,
      rules: rule_name,
      format_time_zone_abbr: format_time_zone_abbr,
      std_offset_from_utc_time: utc_offset
    }

    Tz.PeriodsBuilder.build_periods([zone_line], rule_records, :dynamic_far_future)
    |> Tz.PeriodsBuilder.periods_to_tuples_and_reverse()
  end

  defp iso_days_to_gregorian_seconds({days, {parts_in_day, unit_in_day}}) do
    units_per_second = div(unit_in_day, 86_400)
    div(days * unit_in_day + parts_in_day, units_per_second)
  end

  defp naive_datetime_to_gregorian_seconds(%{calendar: Calendar.ISO, year: year}) when year < 0,
    do: 0

  defp naive_datetime_to_gregorian_seconds(%{calendar: Calendar.ISO} = datetime) do
    NaiveDateTime.to_erl(datetime)
    |> :calendar.datetime_to_gregorian_seconds()
  end

  defp naive_datetime_to_gregorian_seconds(datetime) do
    datetime
    |> NaiveDateTime.convert!(Calendar.ISO)
    |> naive_datetime_to_gregorian_seconds()
  end

  defp gregorian_seconds_to_naive_datetime(seconds) do
    :calendar.gregorian_seconds_to_datetime(seconds)
    |> NaiveDateTime.from_erl!()
  end
end
