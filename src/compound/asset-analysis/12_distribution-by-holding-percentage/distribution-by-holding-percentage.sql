WITH
  decimals_info_token AS (
    SELECT
      decimals
    FROM
      tokens.erc20
    WHERE
      contract_address = {{token_address}}
  ),
  value_transfers_token AS (
    SELECT
      b.value / POWER(10, d.decimals) AS value
    FROM
      erc20_{{chain}}.evt_Transfer AS b
      INNER JOIN {{chain}}.transactions AS tx ON tx.hash = b.evt_tx_hash
      CROSS JOIN decimals_info_token d
    WHERE
      b.contract_address = {{token_address}}
      AND b."from" = 0x0000000000000000000000000000000000000000
    UNION ALL
    SELECT
      - d.value / POWER(10, e.decimals) AS value
    FROM
      erc20_{{chain}}.evt_Transfer AS d
      INNER JOIN {{chain}}.transactions AS tx ON tx.hash = d.evt_tx_hash
      CROSS JOIN decimals_info_token e
    WHERE
      d.contract_address = {{token_address}}
      AND d."to" = 0x0000000000000000000000000000000000000000
  ),
  token_total_supply AS (
    SELECT
      SUM(value) AS total_supply
    FROM
      value_transfers_token
  ),
  token_transfers AS (
    SELECT
      DAY,
      address,
      token_address,
      SUM(amount) AS amount
    FROM
      (
        SELECT
          DATE_TRUNC('day', evt_block_time) AS DAY,
          "to" AS address,
          tr.contract_address AS token_address,
          CAST(value AS DECIMAL (38, 0)) AS amount
        FROM
          erc20_{{chain}}.evt_Transfer AS tr
        WHERE
          contract_address = {{token_address}}
        UNION ALL
        SELECT
          DATE_TRUNC('day', evt_block_time) AS DAY,
          "from" AS address,
          tr.contract_address AS token_address,
          (-1) * (CAST(value AS DECIMAL (38, 0))) AS amount
        FROM
          erc20_{{chain}}.evt_Transfer AS tr
        WHERE
          contract_address = {{token_address}}
      ) AS t
    GROUP BY
      1,
      2,
      3
  ),
  token_balances_with_gap_days AS (
    SELECT
      t.day,
      address,
      SUM(amount) OVER (
        PARTITION BY
          address
        ORDER BY
          t.day
      ) AS balance,
      LEAD(DAY, 1, CURRENT_TIMESTAMP) OVER (
        PARTITION BY
          address
        ORDER BY
          t.day
      ) AS next_day
    FROM
      token_transfers AS t
  ),
  days AS (
    SELECT
      DAY
    FROM
      UNNEST (
        SEQUENCE(
          TRY_CAST(DATE_TRUNC('day', CURRENT_TIMESTAMP) AS TIMESTAMP),
          CAST(
            TRY_CAST(
              TRY_CAST(
                TRY_CAST(DATE_TRUNC('day', CURRENT_TIMESTAMP) AS TIMESTAMP) AS TIMESTAMP
              ) AS TIMESTAMP
            ) AS TIMESTAMP
          ),
          INTERVAL '1' day
        )
      ) AS _u (DAY)
  ),
  token_balance_all_days AS (
    SELECT
      d.day,
      address,
      SUM(
        balance / TRY_CAST(POWER(10, di.decimals) AS DOUBLE)
      ) AS balance
    FROM
      token_balances_with_gap_days AS b
      INNER JOIN days AS d ON b.day <= d.day
      AND d.day < b.next_day
      CROSS JOIN decimals_info_token di
    GROUP BY
      1,
      2
    ORDER BY
      1,
      2
  ),
  token_holders_with_token_value AS (
    SELECT
      b.day AS "Date",
      COUNT(
        CASE
          WHEN b.balance > 0
          AND b.balance <= ts.total_supply * 0.000001 THEN b.address
        END
      ) AS "0-0.0001%",
      COUNT(
        CASE
          WHEN b.balance > ts.total_supply * 0.000001
          AND b.balance <= ts.total_supply * 0.001 THEN b.address
        END
      ) AS "0.0001-0.1%",
      COUNT(
        CASE
          WHEN b.balance > ts.total_supply * 0.001
          AND b.balance <= ts.total_supply * 0.005 THEN b.address
        END
      ) AS "0.1-0.5%",
      COUNT(
        CASE
          WHEN b.balance > ts.total_supply * 0.005
          AND b.balance <= ts.total_supply * 0.01 THEN b.address
        END
      ) AS "0.5-1%",
      COUNT(
        CASE
          WHEN b.balance > ts.total_supply * 0.01 THEN b.address
        END
      ) AS ">1%"
    FROM
      token_balance_all_days AS b
      CROSS JOIN token_total_supply ts
    WHERE
      balance > 0
    GROUP BY
      b.day,
      ts.total_supply
  )
SELECT
  htv_token."Date" AS "Date",
  COALESCE(htv_token."0-0.0001%", 0) AS "0-0.0001%",
  COALESCE(htv_token."0.0001-0.1%", 0) AS "0.0001-0.1%",
  COALESCE(htv_token."0.1-0.5%", 0) AS "0.1-0.5%",
  COALESCE(htv_token."0.5-1%", 0) AS "0.5-1%",
  COALESCE(htv_token.">1%", 0) AS ">1%"
FROM
  token_holders_with_token_value htv_token
ORDER BY
  htv_token."Date";