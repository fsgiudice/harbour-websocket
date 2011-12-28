#include "hbclass.ch"
#include "hbsocket.ch"
#include "hbcompat.ch"
#include "fileio.ch"

#define CRLF chr(13)+chr(10)

//-----------------------------------------//

CLASS HB_Socket

   DATA   cBindAddress INIT "0.0.0.0"

   DATA bDebug
   DATA bOnAccept
   DATA bOnClose
   DATA bOnListen
   DATA bOnRead
   DATA bOnWrite
   DATA bOnProccess
 
   DATA cBuffer
   DATA cLogFile
   DATA cError
 
   DATA hClients
   DATA hMutexUser

   DATA nClientId
   DATA nPort

   DATA lDebug
   DATA lExit        

   DATA pSocket

   METHOD New()
   METHOD End()

   METHOD Listen()

   METHOD NewId() INLINE ::nClientId++
   
   METHOD OnAccept( oClient )
   METHOD OnClose()
   METHOD OnRead( oClient )
   
   METHOD SendData( cText ) 
   
   HIDDEN:
   
   METHOD Debug( cText ) 


ENDCLASS

//-----------------------------------------//

METHOD New( nPort ) CLASS HB_Socket

   DEFAULT nPort TO 8080
   
   ::nClientId = 1
   ::nPort     = nPort
   ::hClients  = hb_Hash()

   ::lExit     = .F.
   ::lDebug    = .F. 
   

RETURN Self

//-----------------------------------------//

METHOD End() CLASS HB_Socket

   LOCAL pClient
   
   for each pClient in ::hClients
      ::OnClose( pClient )
   next
   
   if ::pSocket != NIL
      //hb_socketClose( ::pSocket )
   endif

RETURN nil

//-----------------------------------------//

METHOD Debug( ... ) CLASS HB_Socket
   
   local aParams := hb_aParams()

   IF ::lDebug 
   
      IF hb_IsBlock( ::bDebug )
         Eval( ::bDebug, aParams )
      ELSE
         AEval( aParams, {| u | QOut( u ) } )
      ENDIF
      
   ENDIF

RETURN NIL
//-----------------------------------------//

METHOD Listen() CLASS HB_Socket

   ::pSocket     = hb_socketOpen( )
   ::hMutexUser  = HB_MutexCreate()   

   IF ! hb_socketBind( ::pSocket, { HB_SOCKET_AF_INET, ::cBindAddress, ::nPort } )
      QOut( ::cError :=  "Bind error " + hb_ntos( hb_socketGetError() ) )
      hb_socketClose( ::pSocket )
      RETURN .F.
   ENDIF

   IF ! hb_socketListen( ::pSocket )
      QOut( ::cError :=  "Listen error " + hb_ntos( hb_socketGetError() ) )
      hb_socketClose( ::pSocket )
      RETURN .F.
   ENDIF
      
   if hb_IsBlock( ::bOnListen )
      Eval( ::bOnListen, Self )
   endif
   ::Debug( "LISTEN" )

   hb_ThreadStart( {|| ::OnAccept() } )

   DO WHILE ! ::lExit
   

      inkey( 0.1 )  

      if ::bOnProccess != nil 
         ::lExit = eval( ::bOnProccess, Self )
      else 
         ::lExit := LastKey() == 27
      endif
      
               
   ENDDO    

   ::End()
   
RETURN .T.

//-----------------------------------------//

METHOD OnAccept() CLASS HB_Socket

   local pClientSocket
   local oClient
   
   ::Debug( "ONACCEPT" )
      
   do while ! ::lExit

      if ! Empty( pClientSocket := hb_socketAccept( ::pSocket,, 500 ) )
         ::Debug( "ACCEPTED", pClientSocket )
         hb_mutexLock( ::hMutexUser )
         ::NewId()
         oClient = HB_SocketClient():New( Self )
         oClient:nID = ::nClientId
         oClient:hSocket = pClientSocket
         hb_HSET( ::hClients, ::nClientId, oClient )
         hb_mutexUnlock( ::hMutexUser )
         hb_ThreadStart( {| oClient | ::OnRead( oClient ) }, oClient )
         if ::bOnAccept != NIL
            Eval( ::bOnAccept, Self, oClient )
         endif
      elseif ! ::lExit
         //? "Catched error ",  hb_ntos( hb_socketGetError() )
         //EXIT
      endif
   enddo
   
RETURN nil

//------------------------------------------------------//

METHOD OnClose( oClient ) CLASS HB_Socket
   
   ::Debug( "CLIENT CLOSED", oClient:hSocket, oClient:nID )
   
   hb_mutexLock( ::hMutexUser )
   hb_HDEL( ::hClients, oClient:nID )
   hb_mutexUnlock( ::hMutexUser )     
   
   oClient:End()
   oClient = NIL
   if ::bOnClose != NIL 
      Eval( ::bOnClose, Self )
   endif      


return nil

//------------------------------------------------------//

METHOD OnRead( oClient ) CLASS HB_Socket

   local lMyExit    := .F.
   local cData, oError
   local nLength  := 0
   local nRetry   := 0
   local lActive  := .T.
   local cBuffer
   
   do while ! lMyExit 

      cBuffer = Space( 4096 )   
      TRY
         if ( nLength := hb_socketRecv( oClient:hSocket, @cBuffer,4096, 0, 1000 ) ) > 0
            oClient:cBuffer = AllTrim( cBuffer )
          endif         
      CATCH oError
         ::Debug( oError:Description )
         lMyExit := .t.
      END 

      if lMyExit
         EXIT
      endif
      
      if nLength > 0
         ::Debug( "ONREAD", oClient:hSocket, oClient:cBuffer )
      endif

      if nLength == 0
         lMyExit = .T.         
      elseif nLength > 1         
         if ::bOnRead != NIL
            Eval( ::bOnRead, Self, oClient )
         endif
      endif

   enddo  
   
   ::Debug( "LISTEN FINISHED", oClient:hSocket )   
   
   ::OnClose( oClient )


RETURN nil

//-----------------------------------------//

METHOD SendData( oClient, cSend ) CLASS HB_Socket

   local nLen 

   ::Debug( "SENDING...", cSend )

   DO WHILE Len( cSend ) > 0
      IF ( nLen := hb_socketSend( oClient:hSocket, @cSend ) ) == - 1
         EXIT
      ELSEIF nLen > 0
         cSend = SubStr( cSend, nLen + 1 )     
      ENDIF
   ENDDO
   
RETURN nLen   

//-----------------------------------------//
//-----------------------------------------//
CLASS HB_SocketClient

   DATA hSocket
   DATA nID
   DATA Cargo
   DATA oServer
   DATA cBuffer
   
   METHOD New( oServer )
   
   METHOD End() INLINE ::hSocket := NIL
   
   METHOD SendData( cSend ) INLINE ::oServer:SendData( Self, cSend )

ENDCLASS

//-----------------------------------------//

METHOD New( oSrv ) CLASS  HB_SocketClient

   ::oServer = oSrv

RETURN Self

//-----------------------------------------//

static function LogFile( cFileName, aInfo )

   local hFile, cLine := DToC( Date() ) + " " + Time() + ": ", n
   
   cFileName = hb_dirBase() + cFileName
   
   for n = 1 to Len( aInfo )
      cLine += uValToChar( aInfo[ n ] ) + Chr( 9 )
   next
   cLine += CRLF

   if ! File( cFileName )
      FClose( FCreate( cFileName ) )
   endif

   if( ( hFile := FOpen( cFileName, FO_WRITE ) ) != -1 )
      FSeek( hFile, 0, FS_END )
      FWrite( hFile, cLine, Len( cLine ) )
      FClose( hFile )
   endif

return nil

//---------------------------------------------------------------------------//

static function uValToChar( uVal )

   local cType := ValType( uVal )

   do case
      case cType == "C" .or. cType == "M"
           return uVal

      case cType == "D"
           #ifdef __XHARBOUR__
              if HasTimePart( uVal )
                 return If( Year( uVal ) == 0, TToC( uVal, 2 ), TToC( uVal ) )
              endif
           #endif
           return DToC( uVal )

      #ifdef __HARBOUR__
         #ifndef __XHARBOUR__
            case cType == "T"
               return If( Year( uVal ) == 0, HB_TToC( uVal, '', Set( _SET_TIMEFORMAT ) ), HB_TToC( uVal ) )
         #endif
      #endif

      case cType == "L"
           return If( uVal, ".T.", ".F." )

      case cType == "N"
           return TStr( uVal )

      case cType == "B"
           return "{|| ... }"

      case cType == "A"
           return "{...}"

      case cType == "O"
           return If( __ObjHasData( uVal, "cClassName" ), uVal:cClassName, uVal:ClassName() )

      case cType == "H"
           return "{=>}"

      case cType == "P"
           #ifdef __XHARBOUR__
              return "0x" + NumToHex( uVal )
           #else
              return "0x" + hb_NumToHex( uVal )
           #endif

      otherwise

           return ""
   endcase

return nil

//---------------------------------------------------------------------------//

static function TStr( n )
return AllTrim( Str( n ) )

//---------------------------------------------------------------------------//
