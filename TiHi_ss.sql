WITH BaseCalc AS (

  SELECT 
    l.LocationName, 
    --s.InventoryDateID,
    lf.date,
    v.VendorManager,
    v.SeniorVendorManager,
    v.BuyerCode,
    i.ItemNumber,
    GREATEST(vi.HandlingQuantitySUOM,1) AS HUOMtoSUOM,
    s.PackQuantity * vi.ToStockConversionFactor AS PackQty_SUOM,
    -- find out how many items there are, then see how many boxes you can fill up with them
    ROUND(SAFE_DIVIDE(s.PackQuantity * vi.ToStockConversionFactor, vi.HandlingQuantitySUOM),3) AS Pack_Qty_HUOM,
    s.TiHiLayers * s.TiHiQtyPerLayerHuom AS TIHI_Total_HUOM,
    s.TiHiLayers * s.TiHiQtyPerLayerHuom * GREATEST(vi.HandlingQuantitySUOM,1) AS TIHI_Total_SUOM,

    SAFE_DIVIDE(((lf.LocDemand / EXTRACT(DAY FROM LAST_DAY(lf.Date))) * 14),vi.HandlingQuantitySUOM)  AS PredBiWeeklyDemand_HUOM, -- Biweekly estimate converted to HUOM

  FROM `clark-analytics.aim_import_tables.Stocking` s
  INNER JOIN `prod-ds-wss.AIM.Location_Forecasts_Power_BI` lf
    ON s.InventoryItemID = lf.InventoryItemID
    AND s.VendorID = lf.VendorID
    AND s.LocationID = lf.LocationID
  INNER JOIN `clark-analytics.aim_import_tables.Location` l 
    ON l.LocationID = s.LocationID
  INNER JOIN `clark-analytics.aim_import_tables.VendorItem` vi
    ON s.InventoryItemID = vi.InventoryItemID 
    AND s.VendorID = vi.VendorID 
    AND s.InventoryDateID = vi.InventoryDateID 
  INNER JOIN `clark-analytics.aim_import_tables.Items` i
    ON s.InventoryItemID = i.InventoryItemID 
    AND s.VendorID = i.VendorID
  INNER JOIN `clark-analytics.aim_import_tables.Vendor` v
    ON s.VendorID = v.VendorID

  WHERE l.LocationName IN ('873','874')
    AND s.IsCurrentMax
    AND s.TiHiLayers > 0 
    AND s.TiHiQtyPerLayerHuom > 0
    AND s.InventoryDateID = (SELECT MAX(InventoryDateID) FROM `clark-analytics.aim_import_tables.Stocking`)
    AND lf.Date = (SELECT MIN(DATE_ADD(lfb.Date, INTERVAL 1 MONTH)) FROM `prod-ds-wss.AIM.Location_Forecasts_Power_BI` lfb) -- get the month after the current to avoid blending actuals vs. predicted 
)


SELECT 
  LocationName,
  Date,
  VendorManager,
  SeniorVendorManager, 
  BuyerCode,
  ItemNumber, 
  HUOMtoSUOM,
  Pack_Qty_HUOM, 
  PackQty_SUOM,
  TIHI_Total_HUOM, 
  TIHI_Total_SUOM,

  ROUND(Pack_Qty_HUOM / TIHI_Total_HUOM, 3) AS PackToTIHIRatio,

  CASE
    WHEN MOD(CAST(Pack_Qty_HUOM AS NUMERIC), TIHI_Total_HUOM) = 0 THEN 'Efficient'
    WHEN ROUND(Pack_Qty_HUOM / TIHI_Total_HUOM, 3) > 1 AND MOD(CAST(Pack_Qty_HUOM AS NUMERIC), TIHI_Total_HUOM) / TIHI_Total_HUOM != 0 THEN 'Below Full TiHi'
    ELSE 'Acceptable Partial TiHi'
  END AS StorageEfficiencyScore,



  PredBiWeeklyDemand_HUOM,

   -- If there is enough inventory for the demand then flag w/ sufficient packs, otherwise insufficient 
  CASE
    WHEN PredBiWeeklyDemand_HUOM > Pack_Qty_HUOM THEN "Insufficient Pack Quantity" 
    ELSE "Sufficient Pack Quantity"
  END AS PackQtyDemandCheck,

  ROUND(PredBiWeeklyDemand_HUOM / TIHI_Total_HUOM, 3) AS TIHIOrderRatio,

  /*
    -- if there is ONE OR more TIHI's of items exisiting, order in multiples of TIHI, 
    -- otherwise order the exact amount of packs to satisfy the demand. 

    -> currently discounting OH stock and treating it like safety stock 
    -> 
    */
    CASE
    WHEN PredBiWeeklyDemand_HUOM > Pack_Qty_HUOM THEN
      CASE 
        WHEN (PredBiWeeklyDemand_HUOM >= TIHI_Total_HUOM 
          OR SAFE_DIVIDE(PredBiWeeklyDemand_HUOM, TIHI_Total_HUOM) >= 0.9) 
            THEN (CEIL(SAFE_DIVIDE(PredBiWeeklyDemand_HUOM, TIHI_Total_HUOM)) * TIHI_Total_HUOM) * HUOMtoSUOM
        
        ELSE 
          PredBiWeeklyDemand_HUOM * HUOMtoSUOM
      END
    ELSE NULL
  END AS PackQtyAdj_SUOM

FROM BaseCalc
ORDER BY ROUND(PredBiWeeklyDemand_HUOM / TIHI_Total_HUOM, 3) DESC
;
