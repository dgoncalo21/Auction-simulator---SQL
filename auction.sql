PRINT '';
PRINT 'Started - ' + CONVERT(varchar, GETDATE(), 121);
GO

SET NOCOUNT ON;
USE AdventureWorks;
GO

-- Create the Schema if it does not exists otherwise do nothing 
IF SCHEMA_ID('Auctions') IS NULL
	EXEC('CREATE SCHEMA Auctions AUTHORIZATION dbo');
GO

-- ******************************************************
-- Create Tables
-- ******************************************************

-- Create configuration table
IF OBJECT_ID('Auctions.Config') IS NULL
CREATE TABLE Auctions.Config (ConfigID int NOT NULL IDENTITY PRIMARY KEY,
	MinimumBid money, --0,05
	MinimumPrice int, -- 50$
	Maximumbid int, -- 100%
	InitialBidPricePercentageNM int, --75%
	InitialBidPricePercentageM int, --50%
	DeltaDefaultExpireDate int, -- 7 dias
	StartBidDate datetime, --15 Nov 
	StopBidDate datetime) --28 Nov
GO

-- Polulate configuration table
IF(NOT EXISTS(SELECT 1 FROM Auctions.Config))
INSERT INTO [Auctions].[Config]
           ([MinimumBid]
           ,[MinimumPrice]
		   ,[Maximumbid]
           ,[InitialBidPricePercentageNM]
           ,[InitialBidPricePercentageM]
           ,[DeltaDefaultExpireDate]
           ,[StartBidDate]
           ,[StopBidDate])
     VALUES
           (0.050
           ,50
		   ,100
           ,75
           ,50
           ,7
           ,'2021-11-15'
           ,'2021-11-28')
GO

-- Create auction products table
IF OBJECT_ID('Auctions.AuctionProducts') IS NULL
CREATE TABLE Auctions.AuctionProducts 
	(AuctionID int NOT NULL IDENTITY PRIMARY KEY,
	ProductID int NOT NULL FOREIGN KEY REFERENCES Production.Product (ProductID),
	InitialBidPrice money,
	MaximumBid money,
	CurrentBidPrice money,
	StartDate datetime, 
	ExpireDate datetime,
	CanceledDate datetime,
	SoldDate datetime,
	Status int)
GO

IF OBJECT_ID('Auctions.Bids') IS NULL
CREATE TABLE Auctions.Bids 
	(BidID int NOT NULL IDENTITY PRIMARY KEY, 
	CustomerID int NOT NULL FOREIGN KEY REFERENCES Sales.Customer (CustomerID), 
	AuctionID int NOT NULL FOREIGN KEY REFERENCES Auctions.AuctionProducts  (AuctionID), 
	BidAmmount money NOT NULL, 
	BidDate datetime)
GO


-- ************************************************************************************************************
-- Create SP's
-- ************************************************************************************************************

-------------------------------------------------------------------------------
-- SP to Add product to auction
-------------------------------------------------------------------------------

CREATE OR ALTER PROCEDURE Auctions.uspAddProductToAuction 

	-- Add the parameters for the stored procedure here
	@ProductID int,
	@ExpireDate datetime = NULL,
	@InitialBidPrice money = NULL

AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets FROM
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

DECLARE @MinPrice int;
SELECT @MinPrice = MinimumPrice FROM Auctions.Config WHERE ConfigID = 1

BEGIN TRY
	BEGIN TRANSACTION;

IF EXISTS(

	-- Only products that fulfill the conditions for the auction and products that are not in auction yet can be auctioned

	 SELECT ProductID from Production.Product as P
	 join Production.ProductSubcategory as PS on PS.ProductSubcategoryID = P.ProductSubcategoryID
	 join Production.ProductCategory as PC on PC.ProductCategoryID = PS.ProductCategoryID
	 WHERE ProductID = @ProductID 
	 and P.ListPrice > @MinPrice 
	 and PC.Name != 'Accessories'
	 and P.SellEndDate IS NULL 
	 and P.DiscontinuedDate IS NULL
	) 
 AND NOT EXISTS(SELECT ProductID FROM Auctions.AuctionProducts WHERE ProductID = @ProductID)
		BEGIN


		-- Product exists and is being auctioned for the first time - want to know list price
		-- Setting up variables

		DECLARE @MaximumBid money;				-- Variable for the maxium allowd bid that can be reached
		DECLARE @StartDate datetime = GETDATE();	-- Get the start date that product auction
		DECLARE @ConfigID int = 1;				-- configuration to be used
		DECLARE @Status int = 1;				-- Status =1 as the auction is going to be active
		DECLARE @LitsPrice money;				-- Variable to store the List price for the specific Product ID

		-- Get the List Price for the product ID
		SELECT @LitsPrice = P.ListPrice FROM Production.Product as P WHERE @ProductID = P.ProductID;

		-- Defining maximum bid allowed. This value comes from the configurations table (Default is set to 100%)
		DECLARE @ConfiMaxiumBid money;
		SELECT @ConfiMaxiumBid = Maximumbid FROM Auctions.Config WHERE ConfigID = @ConfigID
		SELECT @MaximumBid = @LitsPrice*@ConfiMaxiumBid/100 FROM Production.Product as P WHERE @ProductID = P.ProductID;

		-- Validate if user specified expire date - if not it is defaulted to 1 week
		IF @ExpireDate IS NULL
			BEGIN

			DECLARE @DeltaDefaultExpireDate int;
			DECLARE @DefaultExpireDate datetime;
			SELECT @DeltaDefaultExpireDate = DeltaDefaultExpireDate FROM Auctions.Config WHERE ConfigID = @ConfigID
			SELECT @DefaultExpireDate = StartBidDate FROM Auctions.Config Where ConfigID = @ConfigID
			SELECT @ExpireDate = DATEADD(DAY,@DeltaDefaultExpireDate,@DefaultExpireDate)
			END

		-- Validate if user specified initial bid price otherwise validate if it is produced inhouse
		IF @InitialBidPrice IS NULL
			BEGIN

			DECLARE @MakeFlag int;
			SELECT @MakeFlag = MakeFlag FROM Production.Product WHERE ProductID = @ProductID		
				IF @MakeFlag = 0 -- If not manufactured in house -75% discount in list price
					BEGIN
					DECLARE @InitialBidPricePercentageNM int;
					SELECT @InitialBidPricePercentageNM = InitialBidPricePercentageNM FROM Auctions.Config WHERE ConfigID = @ConfigID
					SELECT @InitialBidPrice = @LitsPrice*@InitialBidPricePercentageNM/100
					END
				ELSE -- if manufactured in-house - 50% discount in list price
					BEGIN
					DECLARE @InitialBidPricePercentageM int;
					SELECT @InitialBidPricePercentageM = InitialBidPricePercentageM FROM Auctions.Config WHERE ConfigID = @ConfigID
					SELECT @InitialBidPrice = @LitsPrice*@InitialBidPricePercentageM/100
					END


			END

		--Insert variables into table
		INSERT INTO [Auctions].[AuctionProducts]
           ([ProductID]
           ,[InitialBidPrice]
           ,[MaximumBid]
		   ,[CurrentBidPrice]
           ,[StartDate]
           ,[ExpireDate]
		   ,[Status])
		VALUES
           (@ProductID
           ,@InitialBidPrice
           ,@MaximumBid
		   ,@InitialBidPrice
           ,@StartDate
           ,@ExpireDate
		   ,@Status)
		END

ELSE
	THROW 50001, 'Product does not exist, is not valid or is/was already in auction', 0;

		COMMIT TRANSACTION;
END TRY
BEGIN CATCH
	IF (@@TRANCOUNT > 0)
		ROLLBACK TRANSACTION;
		THROW;
END CATCH

END
GO
-------------------------------------------------------------------------------
-- SP to Bid product
-------------------------------------------------------------------------------


CREATE OR ALTER PROCEDURE Auctions.uspTryBidProduct
	@ProductID int,
	@CustomerID int, 
	@BidAmmount money = NULL
AS
BEGIN
	DECLARE @BidIncrease money;
	DECLARE @StartBidDate datetime;
	DECLARE @StopBidDate datetime;
	DECLARE @ExpireDate datetime;
	DECLARE @AuctionID int;
	DECLARE @BidPrice money;
	DECLARE @MaxBidPrice money;

	SELECT @BidIncrease = MinimumBid, @StartBidDate = StartBidDate, @StopBidDate = StopBidDate
	FROM Auctions.Config;

	SELECT @ExpireDate  = ExpireDate
	FROM Auctions.AuctionProducts
	WHERE ProductID=@ProductID;

		----------------------------------
	-- Check if the product is in Auction
	----------------------------------
	SELECT @AuctionID = AuctionID
	FROM Auctions.AuctionProducts
	Where ProductID = @ProductID AND Status=1
	IF @@ROWCOUNT <> 1
		THROW 50004, 'This product is not in auction', 0;

	----------------------------------
	--Check if the customer exists in the database
	----------------------------------
	SELECT @CustomerID=CustomerID
	FROM Sales.Customer
	WHERE CustomerID = @CustomerID
	IF @@ROWCOUNT <> 1
		THROW 50005, 'Customer is not in the database or does not exist', 0;
	
	----------------------------------
	-- Check if the transaction is 
	-- within the allowable date range
	----------------------------------
	IF @ExpireDate >= @StopBidDate
		IF @StartBidDate > GETDATE() OR @StopBidDate < GETDATE() 
			THROW 50002, 'Bidding for this product is no longer allowed', 0;
	ELSE IF @ExpireDate < @StopBidDate 
		IF @StartBidDate > GETDATE() OR @ExpireDate < GETDATE() 
			THROW 50002, 'Bidding for this product is no longer allowed', 0;

    ----------------------------------
	-- Set maximum bid price
	----------------------------------
	SELECT @MaxBidPrice = Maximumbid
	FROM Auctions.AuctionProducts
	Where ProductID = @ProductID

	SELECT @BidPrice = CurrentBidPrice
	FROM Auctions.AuctionProducts
	WHERE AuctionID = @AuctionID;

	----------------------------------
	-- Set the bid increase to the minimum 
	-- or check if the minimum given is allowed
	----------------------------------	

	IF @BidAmmount IS NULL
		SET @BidAmmount = @BidPrice + @BidIncrease;
	ELSE IF @BidAmmount <= @BidPrice
		THROW 50003, 'Bidding ammount has to be higher than the current bidding price' , 0;


	IF @BidAmmount > @MaxBidPrice
		SET @BidAmmount = @MaxBidPrice; -- set to maximum Bid if the bid ammount exceeds it


	IF @BidAmmount <= @MaxBidPrice
	BEGIN 
		INSERT INTO [Auctions].[Bids]
			([CustomerID]
			,[AuctionID]
			,[BidAmmount]
			,[BidDate])
		VALUES
			(@CustomerID
			,@AuctionID
			,@BidAmmount
			,GETDATE())
	END

	IF @BidAmmount = @MaxBidPrice
		BEGIN
			UPDATE Auctions.AuctionProducts
			SET CurrentBidPrice = @BidAmmount,
			SoldDate = GETDATE(),
			Status = 4
			WHERE AuctionID = @AuctionID;
		END
	ELSE
		BEGIN
			UPDATE Auctions.AuctionProducts
			SET CurrentBidPrice = @BidAmmount
			WHERE AuctionID = @AuctionID;
		END;

END
GO

-------------------------------------------------------------------------------
-- SP Search for auction by name
-------------------------------------------------------------------------------

CREATE OR ALTER PROCEDURE Auctions.uspSearchForAuctionBasedOnProductName
-- Add the parameters for the stored procedure here
	@Productname nvarchar(50),
	@StartingOffSet int = NULL,
	@NumberOfRows int = NULL

AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets FROM
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

IF (@NumberOfRows>0 AND @StartingOffSet>=0) OR (@NumberOfRows IS NULL AND @StartingOffSet>=0) OR (@NumberOfRows>0 AND @StartingOffSet IS NULL) OR (@NumberOfRows IS NULL AND @StartingOffSet IS NULL)  -- number of rows and off set validation

	BEGIN
	IF LEN(@Productname)>=3    -- validate if wildcard search has 3 or more characters

		BEGIN
		DECLARE @Tcount int= (Select count(*)            -- Total count of table rows that resulted from the wild search
		FROM Auctions.AuctionProducts as AP		
		Join Production.Product as PP on AP.ProductID = PP.ProductID
		WHERE PP.Name LIKE @Productname and AP.Status=1);

		IF @Tcount>0                   -- if statement that checks if there is any product with the wild search name	
	
			BEGIN
			IF @StartingOffSet IS NOT NULL AND @NumberOfRows IS NOT NULL   -- if statements for the different combinations of null off sets and number of rows

				BEGIN		
				Select PP.Name, AP.ProductID, AP.CurrentBidPrice, PP.ProductNumber, PP.Color, PP.Size, PP.SizeUnitMeasureCode, PP.WeightUnitMeasureCode, PP.Weight, PP.Style, PP.ProductSubcategoryID, PP.ProductModelID, @Tcount as TotalCount
				FROM Auctions.AuctionProducts as AP		  
				Join Production.Product as PP on AP.ProductID = PP.ProductID
				WHERE PP.Name LIKE @Productname and AP.Status=1
				ORDER BY PP.Name ASC         -- it was decided to order by name because the wild search is also done by name
				OFFSET @StartingOffSet ROWS       
				FETCH FIRST @NumberOfRows ROWS ONLY 
				END

			ELSE IF @StartingOffSet IS NULL AND @NumberOfRows IS NOT NULL

				BEGIN		
				Select PP.Name, AP.ProductID, AP.CurrentBidPrice, PP.ProductNumber, PP.Color, PP.Size, PP.SizeUnitMeasureCode, PP.WeightUnitMeasureCode, PP.Weight, PP.Style, PP.ProductSubcategoryID, PP.ProductModelID, @Tcount as TotalCount
				FROM Auctions.AuctionProducts as AP		  
				Join Production.Product as PP on AP.ProductID = PP.ProductID
				WHERE PP.Name LIKE @Productname and AP.Status=1
				ORDER BY PP.Name ASC         
				OFFSET 0 ROWS      -- set variable to 0 if null to show all products 
				FETCH FIRST @NumberOfRows ROWS ONLY 
				END

			ELSE IF @StartingOffSet IS NOT NULL AND @NumberOfRows IS NULL

				BEGIN		
				Select PP.Name, AP.ProductID, AP.CurrentBidPrice, PP.ProductNumber, PP.Color, PP.Size, PP.SizeUnitMeasureCode, PP.WeightUnitMeasureCode, PP.Weight, PP.Style, PP.ProductSubcategoryID, PP.ProductModelID, @Tcount as TotalCount
				FROM Auctions.AuctionProducts as AP		   
				Join Production.Product as PP on AP.ProductID = PP.ProductID
				WHERE PP.Name LIKE @Productname and AP.Status=1
				ORDER BY PP.Name ASC         
				OFFSET @StartingOffSet ROWS      
				FETCH FIRST @Tcount ROWS ONLY -- set variable to Tcount if null to show all products (depeding of the offset)
				END		

			ELSE IF @StartingOffSet IS NULL AND @NumberOfRows IS NULL

				BEGIN		
				Select PP.Name, AP.ProductID, AP.CurrentBidPrice, PP.ProductNumber, PP.Color, PP.Size, PP.SizeUnitMeasureCode, PP.WeightUnitMeasureCode, PP.Weight, PP.Style, PP.ProductSubcategoryID, PP.ProductModelID, @Tcount as TotalCount
				FROM Auctions.AuctionProducts as AP		  
				Join Production.Product as PP on AP.ProductID = PP.ProductID
				WHERE PP.Name LIKE @Productname and AP.Status=1
				ORDER BY PP.Name ASC         
				OFFSET 0 ROWS      -- set variable to 0 if null to show all products 
				FETCH FIRST @Tcount ROWS ONLY -- set variable to Tcount if null to show all products (depeding of the offset)
				END

			END

		ELSE
			THROW 50071,'There are no active auctions that match for this wild search.', 0;
		END

	ELSE
		THROW 50007,'Wildcard searches are not acceptable if wildcard search contains less than 3 characters.', 0;
	END

ELSE
	THROW 50008,'Insert a valid number of rows and starting offset.', 0;
END
GO

-------------------------------------------------------------------------------
-- SP to List Bids Offers history
-------------------------------------------------------------------------------

CREATE OR ALTER PROCEDURE Auctions.uspListBidsOffersHistory

	@CustomerID int,
	@StartTime datetime,
	@EndTime datetime,
	@Active bit = 1

AS
BEGIN
-- Check if the customerID exists in the database 

	SELECT @CustomerID = CustomerID
	FROM Sales.Customer
	WHERE CustomerID = @CustomerID;

IF EXISTS(SELECT CustomerID = @CustomerID FROM Sales.Customer WHERE CustomerID = @CustomerID)
BEGIN
	
	 -- Return products only currently in Auction
     If @Active = 1
     BEGIN
     	SELECT P.Name, AP.MaximumBid, B.BidDate, B.BidAmmount,
     			COALESCE(AP.CanceledDate, AP.SoldDate, AP.ExpireDate) AS EndDate,
     			AP.Status
     		FROM Auctions.AuctionProducts AP 
     		INNER 
     		JOIN Production.Product P 
     		ON AP.ProductID = P.ProductID 
     		INNER
     		JOIN Auctions.Bids B
     		ON AP.AuctionID = B.AuctionID
     		WHERE B.CustomerID = @CustomerID
     		AND B.BidDate >= @StartTime
     		AND B.BidDate <= @EndTime
     		AND Status=1
     END


	 -- Return all the products regardless their status
     ELSE
	 BEGIN
     	SELECT P.Name, AP.MaximumBid, B.BidDate, B.BidAmmount,
     			COALESCE(AP.CanceledDate, AP.SoldDate, AP.ExpireDate) AS EndDate,
     			AP.Status
     		FROM Auctions.AuctionProducts AP 
     		INNER 
     		JOIN Production.Product P 
     		ON AP.ProductID = P.ProductID 
     		INNER
     		JOIN Auctions.Bids B
     		ON AP.AuctionID = B.AuctionID
     		WHERE B.CustomerID = @CustomerID
     		AND B.BidDate >= @StartTime
     		AND B.BidDate <= @EndTime;
     END
END
ELSE
	THROW 50005, 'Customer is not in the database or does not exist', 0;
END
GO

-------------------------------------------------------------------------------
-- SP to Remove product from the Auction
-------------------------------------------------------------------------------

CREATE OR ALTER PROCEDURE Auctions.uspRemoveProductFromAuction
	-- Add the parameters for the stored procedure here
	(@ProductID INT) 
AS
BEGIN
IF EXISTS(SELECT ProductID FROM Auctions.AuctionProducts WHERE ProductID = @ProductID and Status =1) 
	BEGIN
	DECLARE @Status int = 0;

	UPDATE [Auctions].[AuctionProducts]
	SET Status = @Status,
	CanceledDate = GETDATE()
	WHERE ProductID = @ProductID;

	PRINT('Product ' + CAST(@ProductID as VARCHAR(10)) + ' removed from Auction')
	
	END
ELSE
	THROW 50004, 'The specified product is not in the list of active auction products', 0;
END
GO

-------------------------------------------------------------------------------
-- SP to Update Auction Status
-------------------------------------------------------------------------------

CREATE or ALTER PROCEDURE Auctions.uspUpdateProductAuctionStatus

-- This stored procedure updates auction status for all auctioned products. 
-- This stored procedure will be manually invoked before processing orders for dispatch.
-- Each status in the Auction Products column will be updated depending on the condtions 
-- given below. An update of the table AuctionPorducts will be sufficient to complete the stored procedure

AS
BEGIN

	DECLARE @StopBidDate datetime;
	SELECT @StopBidDate = StopBidDate
	FROM Auctions.Config;

	-- If the auction has ended (Not cancelled nor sold but expired) 
	UPDATE Auctions.AuctionProducts 
	SET Status = 2 
	WHERE CanceledDate IS NULL 
	AND SoldDate IS NULL 
	AND (ExpireDate < GETDATE() OR @StopBidDate < GETDATE());

END;
GO