USE [JOINUP]
GO
/****** Object:  StoredProcedure [dbo].[up_repl_WorkOneClaim_Sedna]    Script Date: 05.02.2026 13:43:26 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO




--Created 06.01.2023 by S.Gorban
-- Last update 07.02.2023 by S.Gorban: added @transfertype in corresponding with partner's reference
-- Last update 22.02.2023 by S.Gorban: using universal SP  repl_sendMailForErrorReservations
-- Last update 20.04.2023 by O.Filatova: changing @claim_remark and @hotel_remark
-- Last update 26.04.2023 by O.Filatova: added nationality for tourists
-- Last update 27.06.2023 by O.Filatova: check the presence of first and last tourist 
-- Last update 05.07.2023 by O.Filatova: Comby tours are sent via e-mail only
-- Last update 28.07.2023 by S.Gorban: @http_status processing, increase @post_data and @customers to varchar(max)
-- Last update 04.08.2023 by S.Gorban: @reserve added to transfer "Green Line"
-- Last update 07.11.2023 by O.Filatova: add Gala dinner for sending JSS-21979
-- Last update 23.02.2024 by O.Filaova: check partnercomment for '\' JSS-25791 
-- Last update 05.04.2024 by O.Filatova: change s.servtype  to join servtype t on s.servtype = t.inc and t.servcategory =1
-- Last update 18.04.2024 by O.Filatova: check individual tranfer on value service.privatenote  = '#indtransfer'
-- Last update 20.05.2024 by O.Filatova: send additional services via email for booking via integration JSS-29055
-- Last update 04.06.2024 by O.Filatova: check  cntNotProcessed for max value before  cntNotProcessed+1
-- Last update 12.06.2024 by O.Filatova: check partnercomment for '"' JSS-31060
-- Last update 27.06.2024 by O.Filatova: send Fast Track, CIP and individual transfer only via email JSS-31756
-- Last update 17.07.2024 by O.filatova: send cancel booking via integration JSS-32480
-- Last update 11.10.2024 by O.Filatova: add sending of excursions JSS-36473
-- Last update 19.11.2024 by O.Filatova: add ISNUll for age and birthday of tourists
-- Last update 16.01.2025 by O.Filatova: added check for room ( room must be for the hotel in rhotelpr) JSS-41348
-- Last update 26.03.2025 by O.Filatova: added FREE RIDE transfer CAMO-491
-- Last update 11.07.2025 by O.Filatova: Remove sendinding notification to procedure CAMO-1664
-- Last update 01.08.2025 by O.Filatova: Send booking via e-mail if  Bad response http status, check log CAMO-3042
-- Last update 19.09.2025 by O.Filatova: exclude price calculation for Summers Tour for booking on 2026 CAMO-3894
-- Last update 23.12.2025 by D.Sharenko: adding error message from response to claim_history  SAMOSD-2280
-- Last update 15.12.2025 by D.Sharenko: https://upfamily.atlassian.net/browse/SAMOSD-143
-- Last update 30.12.2025 by D.Zhura: HotFIX SAMOSD-2345
-- Last update 07.01.2026 by D.Sharenko: SAMOSD-2345
-- Last update 09.01.2026 by O.Filatova: include price calculation for Summers Tour for booking SAMOSD-2516
-- Last update 02.02.2026 by O.Filatova: correct roomcode acording to market SAMOSD-2903
-- Last update 05.02.2026 by D.Sharenko: SAMOSD-2856

ALTER procedure [dbo].[up_repl_WorkOneClaim_Sedna]
 @remote varchar(10)='SMT',
 @partner int  = 31696,
 @claim int  ,
 @develop bit=0
as
 begin 
 set nocount on
  declare @data nvarchar(max),  @xml xml, @hdoc int, @url varchar(255), @login varchar(32), @password varchar(32), @Cookie_auth varchar(1024),  @http_status int, @reserve bit = 0, 
	 @boards varchar(30), @market int, @d_flight varchar(16), @b_flight varchar(16), @hotel_net varchar(10), @market_alias varchar(6) , @transfer_net varchar(10)
  declare @inc table (inc int, far_inc int)
  declare @people_status table (people int, status varchar(4), born smalldateTime)
  declare @post_data nvarchar(max),  @order int, @operator int , @adult tinyint, @cost money = 0,
     @child tinyint ,  @customers varchar(max) ='[', @max_child_age tinyint, @htplace int, @hotel_remark varchar(128),   @transfertypeArr tinyint, @transfertypeDep tinyint, 
	 @claim_remark varchar(128) ='',  @updated bit = 0, @cancelled bit =0, @id int, @histMasterInc int, @ClaimHistMsg varchar(255), @pcount tinyint, @infantextracting bit

  
  declare @errmes nvarchar(max),
          @message_from_response nvarchar(max) 


	 --#itjoin 19.09.2025 
	declare @sendNetPrice bit =1
	/*  #itjoin SAMOSD-2516
	select @sendNetPrice = CASE WHEN @remote = 'SMT' AND 
		(select year(datebeg) from claim where inc = @claim) >= 2026 THEN 0 ELSE 1 END
	*/
	--end join  


	--if  not exists (select inc from repl_JU_claimInfo where claim = @claim and (sentViaApi=1 or sentViaEmail=1))
	-- and 
	 if (select status from claim where inc = @claim ) in (3,4,5)  --claim is canceled and was not sent: do not process
	return -1

	if (select rdate from claim  where inc = @claim ) <'20230105'  --rebook or cancel
	or exists (select inc from repl_JU_claimInfo where claim = @claim and (sentViaApi=1 or sentViaEmail=1))
	 begin
	  if (select status from claim where inc = @claim ) in (3,4,5) select @cancelled = 1
	  else select @updated = 1
	  
	  exec repl_sendMailForErrorReservations @CLaim = @claim , @partner = @partner, @cancelled  = @cancelled, @updated = @updated
	  insert into claim_history(transactionid,histtable,recordinc,mode,description,[user],edate,claim,regmod_user_alias)
	  select newid(),1,@claim,'E','Sending reservation via email'+case when @cancelled=1 then '(cancelation)' else  '(rebook)' end +'. Successfully sent',1,getdate(),@claim,null
	  select @histMasterInc = SCOPE_IDENTITY();

	  update claim set sent = 1, unread = 0, edate = getdate(), ienable2send = 0 where inc = @claim
	  if not exists(select * from claim where inc=@claim and status in (3,4,5)) and exists (select *  from claim where inc=@claim and sent =1 and ienable2send =0)
		begin
		 	insert into claim_history_detail (histmaster,histfield,oldvalue,newvalue)
			select @histMasterInc, 17, 'No', 'Yes'		--sent
			union
			select @histMasterInc, 18, 'Yes', 'No'		--ienable2send
		end
	   update [repl_JU_claimInfo] set sentViaEmail = 1,cntProcessed = cntProcessed + 1, Cancelled = @cancelled  where claim =@claim
	   return (0)
	end

	-- itjoin 15.12.2025

    select @market =  far_inc from repl_market where remote = @remote and alias = @market_alias
	select @market_alias  = rm.alias, @market = rm.far_inc from repl_market rm
	   join replcoded rc on rc.remote = rm.remote and rc.tabals = 'mt' and rc.far_inc = rm.far_inc
	   join tour t on t.market = rc.local_inc
	  where t.inc in (select tour from claim where inc = @claim) and rm.remote=@remote

	exec [dbo].[up_GetAuthResponse]
      @market_alias,
	  @remote, 
	  '/Integratiion/AgencyLogin',
	  0,
	  @cookie_auth output,
	  @operator output,
	  @url output,    
	  -- itjoin 07.01.2026
	  @login output,    
	  @password output

	  
	if @develop =1 
	begin 
	  select @url as url
	  select @Cookie_auth as Cookie_auth
	  select @operator as OperatorId       
	end

	declare @result int  
	exec dbo.up_repl_WorkOneClaim_Sedna_CheckHotelPrice
         @remote = @remote,
         @partner = @partner,
         @market_alias = @market_alias,
         @claim = @claim,
		 @cookie_auth = @cookie_auth,
		 @partnerCode = @operator,
	     @url = @url,
		 @result = @result OUTPUT
      
	if @result = 0 
	  return (-1)
	-- end 15.12.2025

	---------- #itjoin 05.07.2023 Comby tours are sent only via email

	If (SELECT count(*) FROM [order] WHERE claim = @claim and partner = @partner and hotel>0)>1
		-----------#itjoin 27.06.2024
		OR EXISTS(SELECT top 1 o.claim FROM [order] o
				JOIN SERVICE s on o.service = s.inc 
				WHERE (s.inc in (12348,12349) or s.servtype = 36)
				AND o.claim = @claim )
				or
		EXISTS(SELECT o.inc FROM [order] o
				JOIN SERVICE s on o.service = s.inc 
				JOIN claim c on o.claim = c.inc 
				WHERE s.privatenote like '%#indtransfer%'
				AND o.claim = @claim and c.cgroup = 21)
       -------end join 
		BEGIN
			SELECT @cancelled = 0, @updated = 0
			exec repl_sendMailForErrorReservations @CLaim = @claim , @partner = @partner, @cancelled  = @cancelled, @updated = @updated

			insert into claim_history(transactionid,histtable,recordinc,mode,description,[user],edate,claim,regmod_user_alias)
			select newid(),1,@claim,'E','Sending reservation via email. Successfully sent',1,getdate(),@claim,null
			select @histMasterInc = SCOPE_IDENTITY();

			update claim set sent = 1, unread = 0, edate = getdate(), ienable2send = 0 where inc = @claim
			if not exists(select * from claim where inc=@claim and status in (3,4,5)) and exists (select *  from claim where inc=@claim and sent =1 and ienable2send =0)
			begin
				insert into claim_history_detail (histmaster,histfield,oldvalue,newvalue)
				select @histMasterInc, 17, 'No', 'Yes'		--sent
				union
				select @histMasterInc, 18, 'Yes', 'No'		--ienable2send
				union
				select @histMasterInc, 19, 'Yes', 'No'		--unread
			end
			update [repl_JU_claimInfo] set sentViaEmail = 1,cntProcessed = cntProcessed + 1, hotel = 1  where claim =@claim

			RETURN(0)
	  	END 

	---------- end 05.07.2023
	  
	 ---------------------------------
	 select @order  = inc,@htplace = htplace, 
		--#itjoin 19.09.2025
		--@hotel_net = round(net,2,0)
		@hotel_net = cast(IIF(@sendNetPrice = 0,0.00,round(net,2,0)) as varchar(10)), 
		--endjoin
		@cost = @cost + @hotel_net,
		@reserve = case when reserve is not null then 1 else 0 end
	 from [order] where hotel>0 and partner = @partner and claim = @claim

	 --#itjoin 20240418
	 select 
		--#itjoin 19.09.2025
		--@transfer_net = cast(sum(round(net,2,0)) as varchar(10))  
		@transfer_net = cast(sum(IIF(@sendNetPrice = 0,0.00,round(net,2,0))) as varchar(10))
		--endjoin
	 from [order]  o
	 join service s on s.inc = o.service
	 join servtype t on s.servtype = t.inc and t.servcategory =1   --#itjoin 05.04.2024
	 where  o.service>0 and o.partner = @partner 
	 and o.claim = @claim

	 select @transfertypeArr = --case when s.servtype = 12 or s.privatenote LIKE '%#indtransfer%' then 10 else 4/*Group*/ end
		case when s.servtype = 12 or s.privatenote LIKE '%#indtransfer%' then 10 --#itjoin 26.03.2025
			 WHEN s.privatenote LIKE '%#FREERIDE%' then 104  else 4/*Group*/ end
	 from [order]  o
	 join service s on s.inc = o.service
	 join servtype t on s.servtype = t.inc and t.servcategory =1   
	 where  o.service>0 and o.partner = @partner 
	 and o.claim = @claim
	 and s.transfertype in (1,2) 

	 select @transfertypeDep = --case when s.servtype = 12 or s.privatenote LIKE '%#indtransfer%' then 10 else 4/*Group*/ end
		case when s.servtype = 12 or s.privatenote LIKE '%#indtransfer%' then 10 --#itjoin 26.03.2025
			 WHEN s.privatenote LIKE '%#FREERIDE%' then 104  else 4/*Group*/ end
	 from [order]  o
	 join service s on s.inc = o.service
	 join servtype t on s.servtype = t.inc and t.servcategory =1   
	 where  o.service>0 and o.partner = @partner 
	 and o.claim = @claim
	  and s.transfertype in (1,3) 

	 if @transfer_net is not null 
	 SET @cost = @cost + @transfer_net

	 /*
	 select @transfer_net = cast(round(net,2,0) as varchar(10)), @transfertype = case when s.servtype = 12 then 10 else 4/*Group*/ end    from [order]  o
	 join service s on s.inc = o.service
	 join servtype t on s.servtype = t.inc and t.servcategory =1   --#itjoin 05.04.2024
	 where  o.service>0 and o.partner = @partner 
	 --and s.servtype in (1,12) 
	 and o.claim = @claim
	 if @transfer_net is not null select @cost = @cost + net from [order]  o
	 join service s on s.inc = o.service
	 join servtype t on s.servtype = t.inc and t.servcategory =1   --#itjoin 05.04.2024
	 where  o.service>0 and o.partner = @partner 
	 --and s.servtype in (1,12) 
	 and o.claim = @claim
	*/
	--end join 
	--Changed by O.Filatova 20.04.2023
	 select @hotel_remark = dbo.Get_ClaimNote_WithNewCosting(isnull(note,''),'') from claim_detail where claim = @claim  --#itjoin 19.10.2025
	 --select @hotel_remark = isnull(partnercomment,'') from claim where inc = @claim 
	 -- if @hotel_remark like '%#%' 
	 --begin
	 -- select @claim_remark = @hotel_remark, @hotel_remark = ''
	 -- select @claim_remark = replace(@claim_remark, '#ordinsdel','')
	 --end

	 SELECT @hotel_remark = replace(@hotel_remark,'\',' ')   --itjoin 23.02.2024
	 SELECT @hotel_remark = replace(@hotel_remark,'"',' ') 	 --itjoin 12.06.2024	
	 SELECT @hotel_remark = replace(@hotel_remark,'''',' ')  --itjoin 12.06.2024	

	 select @pcount = pcount from htplace where inc = @htplace -- itjoin SAMOSD-2856

	 select @max_child_age = ceiling(max(age)) from
		(select isnull(age1max ,0) as  age from htplace where inc = @htplace
		union select isnull(age2max ,0) as age from htplace where inc = @htplace
		union select isnull(age3max ,0) as age from htplace where inc = @htplace
		) t

	 insert into @people_status(people, status, born)
	 select  p.inc,  case p.human 
	 when 'MR' then 'Mr'
	 when 'MRS' then 'Mrs'
	 when 'CHD' then  case when dbo.sto_AgeofPeople (o.datebeg, p.born) >=@max_child_age then
	 case when p.male = 1 then 'Mr' else 'Mrs' end else 'Chd' end
	 when 'INF' then 'Inf'
	 end,
	 p.born
	 from people p
	 join opeople op on op.people = p.inc and op.[order] = @order
	 join [order] o on o.inc = op.[order]

	 if @@rowcount <> isnull(@pcount, 0)  -- itjoin SAMOSD-2856
	 begin
	   set @infantextracting = 1
	   
       delete ps from @people_status ps   -- удаляем из people_status туриста с минимальным возрастом
	   where ps.inc = (select top 1 inc from @people_status order by born)
	 end

	 if @market is null
	  begin
	   print 'Wrong market alias!'
	   update [repl_JU_claimInfo] set cntNotProcessed = cntNotProcessed + 1, errMsg = 'Wrong market' where claim =@claim
	   
		if exists (select inc from repl_JU_claimInfo where claim = @claim and (sentViaApi=1 or sentViaEmail =1)) select @updated = 1
		exec repl_sendMailForErrorReservations @CLaim = @claim ,@partner = @partner,  @cancelled  = 0, @updated = @updated
			insert into claim_history(transactionid,histtable,recordinc,mode,description,[user],edate,claim,regmod_user_alias)
			select newid(),1,@claim,'E','Sending reservation via email. Successfully sent',1,getdate(),@claim,null
			select @histMasterInc = SCOPE_IDENTITY();

			update claim set sent = 1, unread = 0, edate = getdate(), ienable2send = 0 where inc = @claim
			if not exists(select * from claim where inc=@claim and status in (3,4,5)) and exists (select *  from claim where inc=@claim and sent =1 and ienable2send =0)
			begin
				insert into claim_history_detail (histmaster,histfield,oldvalue,newvalue)
				select @histMasterInc, 17, 'No', 'Yes'		--sent
				union
				select @histMasterInc, 18, 'Yes', 'No'		--ienable2send
				union
				select @histMasterInc, 19, 'Yes', 'No'		--unread
			end
			update [repl_JU_claimInfo] set sentViaEmail = 1,cntProcessed = cntProcessed + 1  where claim =@claim
	   return (0)
	  end

-- Last update 07.01.2026 by D.Sharenko SAMOSD-2345 
/*
-- Last update 30.12.2025 by D.Zhura: HotFIX SAMOSD-2345
	select 
     @url =  [url], 
     @login = rpc.[name],
	 @password =  rpc.psw 
   from repl_remote rr 
	 join repl_partners_creds rpc  
	   on   rpc.[remote]=rr.[remote] 
	    and rpc.market = @market
	where rr.[remote]=@remote
-- Last update 30.12.2025 by D.Zhura: HotFIX SAMOSD-2345
*/ 
-- Last update 07.01.2026 D.Sharenko SAMOSD-2345 
  	
	select @adult = count(people) from @people_status
	where status in ('Mr','Mrs')

	select @child = count(people) from  @people_status
	where status in  ('Chd','Inf')

	select top 1 @d_flight = f.name 
	from [order] o
	join freight f on f.inc = o.freight
	where o.claim = @claim and o.freight>0 and f.isback=0


	select top 1 @b_flight = f.name 
	from [order] o
	join freight f on f.inc = o.freight
	where o.claim = @claim and o.freight>0 and f.isback=1


 select @post_data = '[{
"Voucher":"'+cast(@claim as varchar(10)) +'",
"CheckinDate": "'+convert(varchar(10), o.datebeg,126)+'",
"CheckOutDate": "'+convert(varchar(10), o.dateend,126)+'",
 "HotelId": '+ cast (rch.far_inc as varchar(10)) +',
 "OperatorId": '+ cast (@operator as varchar(10)) +',
 "Adult": '+cast (@adult as varchar(2))+ ',
 "Child": '+cast (@child as varchar(2))+ ',
 "BoardId": '+ cast (rcm.far_inc as varchar(10)) +',
 "RoomTypeId": '+ cast (rcr.far_inc as varchar(10)) +',
 "SourceId": "'+cast(@claim as varchar(10)) +'",
 '
  from [order] o
  join replcoded rch on rch.remote = @remote and rch.tabals = 'hl' and rch.local_inc = o.hotel
  join replcoded rcm on rcm.remote = @remote and rcm.tabals = 'ml' and rcm.local_inc = o.meal
  join replcoded rcr on rcr.remote = @remote and rcr.tabals = 'rm' and rcr.local_inc = o.room
  join repl_buffer rb on rb.remote =@remote and rb.tabals = 'RM_HT' and rb.far_inc = rcr.far_inc and rb.id = rch.far_inc
  where o.inc = @order 
  --#itjoin 16.01.2025
  and rcr.far_inc in (select distinct room from rhotelpr where remote = @remote
	and (market = @market or ISNULL(market,-2147483647)=-2147483647)  --#itjoin 02.02.2026
	and hotel =rch.far_inc )
	--endjoin


if @develop =1 select @post_data as order_data
 
 select @customers = @customers + '
  {
  "Title": "'+ps.status +'",
  "FirstName":"'+ right (p.lname, len(p.lname) - patindex('% %', p.lname) )+'",' +
 -- "LastName":"'+left (p.lname,  patindex('% %', p.lname)-1)+'",  27.06.2023 
 '
  "LastName":"'+left (p.lname,  CASE WHEN (patindex('% %', p.lname)-1)<0 then 0 else (patindex('% %', p.lname)-1) end) +'",
  "BirthDate": "'+ISNULL(convert(varchar(10), p.born,126),'')+'",
  "Age": ' + ISNULL(cast(dbo.sto_AgeofPeople (o.datebeg, p.born) as varchar(3)),'') +',
  "PassNo": "' + isnull(substring(p.pserie,3,len(p.pserie)),'') +isnull(p.pnumber,'') + '",
  "PassSerial":  "' + isnull(left(p.pserie,2),'') + '",
  "ArrivalFlightNumber": "'+isnull(@d_flight,'no flight')+'",
  "DepartureFlightNumber": "'+isnull(@b_flight,'no flight')+'",
  "ArrivalFlightTime": "'+convert(varchar(10), o.datebeg,126)+'",
  "DepartureFlightTime": "'+convert(varchar(10), o.dateend,126)+'",
  ' + CASE  WHEN rs.inc is not null THEN    --26.04.2023 by O.Filatova: added nationality for tourists
  '"Nationality": "' + left(rs.name, 13) +'",
  "NationalityId": ' + CAST(rs.far_inc as varchar(10)) + ','
  ELSE '' END + '
   ' + case when @transfertypeArr is not null then '"ArrTransferType": '+ cast(@transfertypeArr as varchar(3)) +',
  "IsArrivalTransfer": 1,
  '
  else
  '"IsArrivalTransfer": 0,
  '
  end +
  case when @transfertypeDep is not null then
  '"DepTransferType": '+ cast(@transfertypeDep as varchar(3)) +',
  "IsDepartureTransfer": 1,
  ' else 
  '"IsDepartureTransfer": 0,' end+
  '"SourceId": "'+cast(p.inc as varchar(12))+ '"
            },'
  --case when @transfertype is not null then '"ArrTransferType": '+ cast(@transfertype as varchar(3)) +',
  --"DepTransferType": '+ cast(@transfertype as varchar(3)) +',
  --"IsArrivalTransfer": 1,
  --"IsDepartureTransfer": 1,' else 
  --'"IsArrivalTransfer": 0,
  --"IsDepartureTransfer": 0,' end+
  --'"SourceId": "'+cast(p.inc as varchar(12))+ '"
  --          },'
	from @people_status ps 
	join people p on p.inc = ps.people
	join opeople op on op.people = p.inc
	join [order] o on o.inc = op.[order]
	left join [replcoded] rc  on p.state = rc.local_inc and rc.remote = @remote and tabals = 'st'
	left join [repl_state] rs on rs.far_inc = rc.far_inc and rc.remote = rs.remote
	where o.inc =  @order


	select @customers = SUBSTRING(@customers,1,len(@customers)-1) + ']'

	if @develop =1 select @customers as people_data

	-- #itjoin 07.11.2023
	DECLARE @GalaDinner varchar(100)

	if exists(select top 1 * from  [order] o
				inner join service s on o.service = s.inc
				where claim = @claim and  s.servtype = 7)
		select 
			--#itjoin 19.09.2025
			--@GalaDinner = cast(sum(isnull(net,0)) as varchar(10)) 
			@GalaDinner = cast(sum(IIF(@sendNetPrice = 0,0.00,isnull(net,0))) as varchar(10)) 
			--endjoin
		from [order] o
			inner join service s on o.service = s.inc
		where claim = @claim and  s.servtype = 7
	-- end  #itjoin 07.11.2023

	
  select @post_data = @post_data + '"Customers": '+ @customers + ',
  "HotelRemark": "'+@hotel_remark + '",
  "SaleDate": "'+convert(varchar(10),GETDATE(),126)+'",
  "IsReservationChanged": false,
   "ReservationRemark": "REF.N. '+ cast(@claim as varchar(10)) +', calculation: ' + @hotel_net + '(hotel) +  ' +isnull(@transfer_net,'0.00') + '(transfer) ' + 
   Case  WHEN @GalaDinner is null then '' else ' + ' + @GalaDinner + ' (GALA)' END +';'  +@claim_remark+'",  
   "Code2": "'+ @hotel_net + 'EUR + ' +isnull(@transfer_net,'0.00')+'EUR' +
   + case when @reserve =1 then ', Green Line' else '' end + 
   +Case  WHEN @GalaDinner is null then '' else ' + ' + @GalaDinner + 'EUR' END + '" }   
  '+  ']' 

 if @develop =1 select @post_data as post_data
 if @develop =1 select @url , '/Integratiion/InsertReservation?UserName=',@login ,'&Password=',@password,'&voucherNo=',cast(@claim as varchar(10))
 
  SELECT   @xml= [dbo].[clr_http_request]('POST', @url + '/Integratiion/InsertReservation?UserName='+@login +'&Password='+@password+'&voucherNo='+cast(@claim as varchar(10)),
      @post_data, '<Headers>
			<Header Name="Cookie">'+ @Cookie_auth +'</Header>
			<Header Name ="Content-Type">application/json</Header>
			</Headers>',  Null)
	if @develop =1 select @xml as raw_data
	select @data = @xml.value('Response[1]/Body[1]', 'NVARCHAR(MAX)'), @http_status= @xml.value('Response[1]/StatusNumber[1]', 'int')
	
	if @http_status <>200
	begin
	 print 'http status :'
	 print cast(@http_status as varchar(100))

	 -- itjoin SAMOSD-2280
	 
	 set @errmes = 'Sending reservation via integration. Bad response http status, check log'
	 
	 -- Last update 30.12.2025 by D.Zhura: HotFIX SAMOSD-2345
	 IF TRY_CAST(@data AS XML).exist('(/Response/StatusCode)[1]') = 1
		BEGIN
			SET @message_from_response = TRY_CAST(@data AS XML).value('(/Response/StatusCode)[1]', 'NVARCHAR(MAX)');
		END
	 --set @message_from_response = cast(@data as xml).value('Response[1]/StatusCode[1]', 'NVARCHAR(MAX)')
	 -- Last update 30.12.2025 by D.Zhura: HotFIX SAMOSD-2345

     set @errmes = isnull(@message_from_response + ' ','') +  @errmes
     
	 -- endjoin

      insert into JOINUP_LOGS.dbo.repl_Sedna_claim_log
	   (remote, claim, request, response, rdate, API_Category)
	   select @remote, @claim, @post_data, cast(@xml as varchar(max)), getdate(), 'SENT'
	 update repl_JU_claiminfo set cntNotProcessed = cntNotProcessed + 1, errMsg = 'Response http status: ' + cast(@http_status as varchar(100)) where claim =  @claim 
	  insert into claim_history(transactionid,histtable,recordinc,mode,description,[user],edate,claim,regmod_user_alias)
      select newid(),1,@claim,'E',@errmes,1,getdate(),@claim,null

	  update [repl_JU_claimInfo] set cntNotProcessed = CASE WHEN cntNotProcessed<32767 THEN cntNotProcessed + 1 ELSE  cntNotProcessed END, -- #itjoin 04.06.2024
		errMsg = @xml.value('result[1]/reservation[1]/Message[1]', 'varchar(max)') where claim =@claim

	   --#itjoin 01.08.2025 
		if exists (select inc from repl_JU_claimInfo where claim = @claim and (sentViaApi=1 or sentViaEmail =1)) select @updated = 1
		exec repl_sendMailForErrorReservations @CLaim = @claim, @partner = @partner, @cancelled  = 0, @updated = @updated
		insert into claim_history(transactionid,histtable,recordinc,mode,description,[user],edate,claim,regmod_user_alias)
		select newid(),1,@claim,'E','Sending reservation via email. Successfully sent',1,getdate(),@claim,null
		select @histMasterInc = SCOPE_IDENTITY();

		update claim set sent = 1, unread = 0, edate = getdate(), ienable2send = 0 where inc = @claim
		if not exists(select * from claim where inc=@claim and status in (3,4,5)) and exists (select *  from claim where inc=@claim and sent =1 and ienable2send =0)
		begin
			insert into claim_history_detail (histmaster,histfield,oldvalue,newvalue)
			select @histMasterInc, 17, 'No', 'Yes'		--sent
			union
			select @histMasterInc, 18, 'Yes', 'No'		--ienable2send
			union
			select @histMasterInc, 19, 'Yes', 'No'		--unread
		end
		update [repl_JU_claimInfo] set sentViaEmail = 1,cntProcessed = cntProcessed + 1, hotel = 1  where claim =@claim
		--end join
		
	 return -1
	end
	  if @data<> '[]'
	   begin

	    set @data = '{reservation:' + @data + '}'
	    select @xml = dbo.xf_Json2XML(@data)
	    if @develop =1 select @xml

		insert into JOINUP_LOGS.dbo.repl_Sedna_claim_log
		(remote, claim, request, response, rdate, API_Category)
		select @remote, @claim, @post_data, @data, getdate(), 'SENT'

		
		select @id = @xml.value('result[1]/reservation[1]/RecId[1]', 'int')
        if isnull(@id,0)<>0
		begin 
			update [order] set id = @id 	where inc = @order
			
			insert into claim_history(transactionid,histtable,recordinc,mode,description,[user],edate,claim,regmod_user_alias)
			select newid(),1,@claim,'E','Sending reservation via integration. Successfully sent',1,getdate(),@claim,null
			select @histMasterInc = SCOPE_IDENTITY();

			update claim set sent = 1, unread = 0, edate = getdate(), ienable2send = 0 where inc = @claim
			if not exists(select * from claim where inc=@claim and status in (3,4,5)) and exists (select *  from claim where inc=@claim and sent =1 and ienable2send =0)
			begin
				insert into claim_history_detail (histmaster,histfield,oldvalue,newvalue)
				select @histMasterInc, 17, 'No', 'Yes'		--sent
				union
				select @histMasterInc, 18, 'Yes', 'No'		--ienable2send
				union
				select @histMasterInc, 19, 'Yes', 'No'		--unread
			end

		 declare @subject varchar(200), @body varchar (2000)

		 --exec [dbo].[repl_sendMailForServicesOnReservations] @claim = @claim  --#itjoin 20.05.2024	

		 select @subject  = 'Summer Tour integration. Reservation '+ cast(@claim as varchar(10)) + ' sending'
		 select @body = '<html><body> Reservation  '+ cast(@claim as varchar(10)) + ' was successfully sended via integration. </body></html>'
		 --#itjoin 11.07.2025
		 --EXEC msdb.dbo.sp_send_dbmail		-- reservation email
			--@profile_name    = 'robot ua',  
			--@recipients      = 'turkey@joinup.ua', 
			--@copy_recipients = 's.gorban@up.family',
			--@body            = @body,
			--@subject         = @subject,
			--@body_format     = 'HTML'

		EXEC repl_sendMailNotification
			@claim =@claim ,
			@subject =@subject,
			@body = @body,
			@recipients = 'turkey@joinup.ua',
			@copy_recipients = '',
			@profile_from  ='robot ua',
			@body_format = 'HTML',
			@changeRecipients = 1

		--end join
	    update [repl_JU_claimInfo] set cntProcessed = cntProcessed + 1, errMsg = '',sentViaApi = 1, hotel = 1 where claim =@claim

		--#itjoin 11.10.2024
		exec [dbo].[up_repl_WorkOneClaim_SendExcurtion_Sedna]
			 @remote = @remote,
			 @partner  = @partner,
			 @claim  = @claim,
			 @login =@login, 
			 @password =@password,
			 @max_child_age = @max_child_age, 
			 @developer = @develop
		--endjoin

	   end
	   -- else
	   if isnull(@id, 0) = 0 or isnull(@infantextracting, 0) = 1   -- SAMOSD-2856
	   begin

	    -- itjoin SAMOSD-2280
		declare @json_error nvarchar(max)
		if isnull(@id, 0) = 0     -- SAMOSD-2856
		begin
		  set @json_error  = replace(@data,'{reservation:','{"reservation":') 

          if ISJSON(@json_error) = 1 --30.12.2025 by D.Zhura: HotFIX SAMOSD-2345
		  select @message_from_response = json_value(@json_error, '$.reservation.Message');
	      
		  if isnull(@message_from_response,'') <> ''
			begin
				select @message_from_response =  'Error sending reservation via integration: ' + @message_from_response
				insert into claim_history(transactionid,histtable,recordinc,mode,description,[user],edate,claim,regmod_user_alias)
				select newid(),1,@claim,'E',@message_from_response,1,getdate(),@claim,null
			end
        end
		-- endjoin

	    set @errmes  = 'Sending reservation via email. Successfully sent'
		update [repl_JU_claimInfo] set cntNotProcessed = CASE WHEN cntNotProcessed<32767 THEN cntNotProcessed + 1 ELSE  cntNotProcessed END, -- #itjoin 04.06.2024
		errMsg = @xml.value('result[1]/reservation[1]/Message[1]', 'varchar(max)') where claim =@claim
	   
		if exists (select inc from repl_JU_claimInfo where claim = @claim and (sentViaApi=1 or sentViaEmail =1)) select @updated = 1
		exec repl_sendMailForErrorReservations @CLaim = @claim, @partner = @partner, @cancelled  = 0, @updated = @updated
		insert into claim_history(transactionid,histtable,recordinc,mode,description,[user],edate,claim,regmod_user_alias)
		select newid(),1,@claim,'E',@errmes,1,getdate(),@claim,null
		select @histMasterInc = SCOPE_IDENTITY();		  

		update claim set sent = 1, unread = 0, edate = getdate(), ienable2send = 0 where inc = @claim
		if not exists(select * from claim where inc=@claim and status in (3,4,5)) and exists (select *  from claim where inc=@claim and sent =1 and ienable2send =0)
		begin
			insert into claim_history_detail (histmaster,histfield,oldvalue,newvalue)
			select @histMasterInc, 17, 'No', 'Yes'		--sent
			union
			select @histMasterInc, 18, 'Yes', 'No'		--ienable2send
			union
			select @histMasterInc, 19, 'Yes', 'No'		--unread
		end
		update [repl_JU_claimInfo] set sentViaEmail = 1,cntProcessed = cntProcessed + 1, hotel = 1  where claim =@claim

 	   end
	   end

	return (0)
 end
