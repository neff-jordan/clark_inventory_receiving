WITH 
  CalcFields AS (
    SELECT 
      l.LocationName,
      lf.ItemNumber,
      lf.Date, 

      GREATEST(vi.HandlingQuantitySUOM,1) AS HUOMtoSUOM,
      s.TiHiLayers,
      s.TiHiQtyPerLayerHuom,

      CAST(vi.SkidQuantity AS NUMERIC) AS SkidQty,
      GREATEST(vi.HandlingQuantitySUOM,1) * TiHiQtyPerLayerHuom AS LayerQty, 
      CAST(s.PackQuantity * vi.ToStockConversionFactor AS NUMERIC) AS PackQty_SUOM, 
      ROUND(SAFE_DIVIDE(s.PackQuantity * vi.ToStockConversionFactor, GREATEST(vi.HandlingQuantitySUOM,1)),3) AS PackQty_HUOM,

      (lf.LocDemand / EXTRACT(DAY FROM LAST_DAY(lf.Date))) * 14 AS PredBiWeeklyDemand_SUOM,
      SAFE_DIVIDE(((lf.LocDemand / EXTRACT(DAY FROM LAST_DAY(lf.Date))) * 14), GREATEST(vi.HandlingQuantitySUOM,1))  AS PredBiWeeklyDemand_HUOM

    FROM `clark-analytics.aim_import_tables.Stocking` s
    INNER JOIN `prod-ds-wss.AIM.Location_Forecasts_Power_BI` lf
      ON s.InventoryItemID = lf.InventoryItemID
      AND s.VendorID = lf.VendorID
      AND s.LocationID = lf.LocationID
    INNER JOIN `clark-analytics.aim_import_tables.VendorItem` vi
      ON s.InventoryItemID = vi.InventoryItemID 
      AND s.VendorID = vi.VendorID 
      AND s.InventoryDateID = vi.InventoryDateID 
    INNER JOIN `clark-analytics.aim_import_tables.Location` l
      ON s.LocationID = l.LocationID

    WHERE s.IsCurrentMax
      AND s.InventoryDateID = (SELECT MAX(InventoryDateID) FROM `clark-analytics.aim_import_tables.Stocking`)
      AND lf.Date = (SELECT MIN(DATE_ADD(lfb.Date, INTERVAL 1 MONTH)) FROM `prod-ds-wss.AIM.Location_Forecasts_Power_BI` lfb) 
  ),                

  PacksToAddCalc AS (
  SELECT *,
    CASE 
      WHEN PredBiWeeklyDemand_HUOM > PackQty_HUOM
        THEN PredBiWeeklyDemand_HUOM - PackQty_HUOM
      ELSE NULL
    END AS PacksToAdd,

  -- Ex walkthrough: pred = 285, skid = 100, OH = 190 
  -- 285/100 = 2.85, Ceil(2.85) = 3, 3*100 = 300,       aka we need 300 HUOM to meet demand forecasts
    (CEIL(SAFE_DIVIDE(PredBiWeeklyDemand_HUOM, skidqty)) * SkidQty) AS skidDemandMatch,
    (CEIL(SAFE_DIVIDE(PredBiWeeklyDemand_HUOM, layerqty)) * LayerQty) AS LayerDemandMatch, 

  FROM CalcFields
  )

  SELECT
    LocationName,
    ItemNumber,
    PacksToAddCalc.Date,
    SkidQty,
    LayerQty, 
    PackQty_HUOM,
    HUOMtoSUOM,
    PackQty_SUOM,
    PredBiWeeklyDemand_HUOM,
    
    CASE
      WHEN PredBiWeeklyDemand_HUOM > PackQty_HUOM THEN "Insufficient Pack Quantity" 
      ELSE "Sufficient Pack Quantity"
    END AS PackQtyDemandCheck,

    ROUND(SAFE_DIVIDE(PredBiWeeklyDemand_HUOM, NULLIF(SkidQty,0)), 3) AS PalletUtilizationRatioForNewOrder, 
    ROUND(SAFE_DIVIDE(PredBiWeeklyDemand_HUOM, NULLIF(LayerQty,0)), 3) AS LayerUtilizationRatioForNewOrder, 


    /*
    If there is over a pallet, order in multiples of pallets
    If a pallet is 90% or more full, round up to a full pallet
    If there is over a layer, order in multiples of layers
    If a layer is 90% or more full, round up to a full layer 
    Otherwise return the number of packs needed to fulfull demand

    final PackQtyAdj is converted back to SUOM (HUOM_Converter * x)
    */
    /*
    My assumptions are that we do not factor in OH packs and treat them as safety stock. From here, find the amount needed to satisfy demand in efficient pack quantities.
    */
    CASE
      WHEN PredBiWeeklyDemand_HUOM > PackQty_HUOM THEN 
        CASE 
          -- If demand is more than 1 full skid, use skid-based ordering
          WHEN NULLIF(SkidQty,0) IS NOT NULL -- if skidqty has a value, run through logic
            AND PredBiWeeklyDemand_HUOM >= NULLIF(SkidQty,0) 
            OR PredBiWeeklyDemand_HUOM/NULLIF(SkidQty,0) >= .9 
              THEN skidDemandMatch * HUOMtoSUOM
          
          -- If demand is more than 1 layer use layer-based ordering  
          WHEN NULLIF(LayerQty,0) IS NOT NULL 
            AND (PredBiWeeklyDemand_HUOM >= NULLIF(LayerQty, 0) 
            OR PredBiWeeklyDemand_HUOM/NULLIF(LayerQty, 0) >= .9)
              THEN LayerDemandMatch * HUOMtoSUOM
          
          -- If demand is less than 1 layer, order exact packs needed
          ELSE 
            PredBiWeeklyDemand_HUOM * HUOMtoSUOM 

        END
      ELSE NULL
    END AS PackQtyAdj

  FROM PacksToAddCalc
  ORDER BY ROUND(SAFE_DIVIDE(PredBiWeeklyDemand_HUOM, SkidQty), 3) DESC, PredBiWeeklyDemand_HUOM > PackQty_HUOM
;
