package openlife.server;
import haxe.Timer;
import haxe.Exception;
import sys.net.Socket;
import sys.thread.Thread;
import sys.thread.Mutex;
import sys.net.Host;
class ThreadServer
{
    public var socket:Socket;
    public var port:Int = 8005;
    public var maxCount:Int = -1;
    public var listenCount:Int = 10;
    public static inline var setTimeout:Int = 30;
    public var server:Server;
    public function new(server:Server,port:Int)
    {
        socket = new Socket();
        this.port = port;
        this.server = server;
        create();
    }
    public function create()
    {
        socket.bind(new Host("0.0.0.0"),port);
        trace('bind $port');
        socket.listen(listenCount);
        while (true) 
        {
            Thread.create(connection).sendMessage(socket.accept());
        }
    }
    private function connection()
    {
        var socket:Socket = cast Thread.readMessage(true);
        socket.setBlocking(false);
        socket.setFastSend(true);
        var connection = new Connection(socket,server);
        var message:String = "";
        var ka:Float = Timer.stamp();
        while (connection.running)
        {
            try {
                message = socket.input.readUntil("#".code);
                ka = Timer.stamp();
            }catch(e:Dynamic)
            {
                if (e != haxe.io.Error.Blocked)
                {
                    connection.close();
                    break;
                }else{
                    if (Timer.stamp() - ka > 20) 
                    {
                        connection.close();
                    }
                }
            }
            Sys.sleep(0.1);
            if (message.length == 0) continue;
            try {
                server.process(connection,message);
                message = "";
            }catch(e:Exception)
            {
                trace(e.details());
                error("---STACK---\n" + e.details());
                connection.close();
                break;
            }
        }
    }
    private function error(message:String) 
    {
        
    }
}