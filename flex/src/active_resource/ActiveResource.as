package active_resource
{
	
	import bulk_api.BulkUtility;
	
	import com.adobe.serialization.json.JSONDecoder;
	
	import flash.utils.getDefinitionByName;
	import flash.utils.getQualifiedClassName;
	
	import mx.collections.ArrayCollection;
	import mx.core.mx_internal;
	import mx.messaging.messages.HTTPRequestMessage;
	import mx.messaging.messages.IMessage;
	import mx.rpc.AsyncResponder;
	import mx.rpc.AsyncToken;
	import mx.rpc.events.FaultEvent;
	import mx.rpc.events.ResultEvent;
	import mx.rpc.http.HTTPService;
	import mx.utils.Base64Encoder;
	import mx.utils.ObjectProxy;
	import mx.utils.StringUtil;
		
	/**
	 * A dynamic class that maps to a Resource. Can be used for CRUD operations.
	 * 
	 * Is based on bulk_api.ActiveResource and common code will be factored out between 
	 * the bulk_api and the active_resource projects.
	 * 
	 * Follows the Rails REST convention. For the employees resource the following calls are supported:
	 * 
     *                Verb    Url                      Action
	 *      employees GET    /employees(.:format)      index
	 *                POST   /employees(.:format)      create
	 *       employee GET    /employees/:id(.:format)  show
	 *                PUT    /employees/:id(.:format)  update
	 *                DELETE /employees/:id(.:format)  delete
	 *
	 */
	public dynamic class ActiveResource extends ObjectProxy
	{
		static public var baseUrl:String = "http://localhost:3000";
		public function ActiveResource(attributes:Object=null) {
			super();
			BulkUtility.copyAttributes(attributes, this);
		}
		
		static public function find(clazz:Class, id:Number, findOptions:Object=null):AsyncToken {
			var http:HTTPService = new HTTPService();
			http.url = getBaseUrl(findOptions)+"/"+ClassRegistry.resourceForClass(clazz)+"/"+id+".json";
			http.resultFormat = "text";
			return send(clazz, http);
		}
		
		static public function findAll(clazz:Class, findOptions:Object=null):AsyncToken {
			var http:HTTPService = new HTTPService();
			http.url = getBaseUrl(findOptions)+"/"+ClassRegistry.resourceForClass(clazz)+postFix(findOptions)+".json";
			http.resultFormat = "text";	
			var call:AsyncToken = send(clazz, http);
			if (findOptions&&findOptions.credentials) setCredentials(call.message as HTTPRequestMessage, findOptions.credentials);
			return call			
		}
		
		static protected function setCredentials(message:HTTPRequestMessage,credentials:Object):void {
			var encoder:Base64Encoder = new Base64Encoder();
			encoder.insertNewLines = false; 
			encoder.encode(credentials.username+":"+credentials.password);
			message.httpHeaders["Authorization"] = "Basic " + encoder.toString();;  			
		}
		
		static public function create(clazz:Class, data:Object, saveOptions:Object=null):AsyncToken {
			var http:HTTPService = new HTTPService();
			http.url = getBaseUrl(saveOptions)+"/"+ClassRegistry.resourceForClass(clazz)+".json";
			http.method = "POST";
			http.contentType = "application/json";			
			http.resultFormat = "text";
			return send(clazz, http, RailsEncoder.objectToRails(data, saveOptions), data)
		}
		
		static public function update(clazz:Class, data:Object, saveOptions:Object=null):AsyncToken {
			var http:HTTPService = new HTTPService();
			http.url = getBaseUrl(saveOptions)+"/"+ClassRegistry.resourceForClass(clazz)+"/"+data.id+".json";
			http.method = "POST";
			http.contentType = "application/json";						
			http.headers={X_HTTP_METHOD_OVERRIDE:'put', 'X-HTTP-METHOD-OVERRIDE':'put'}; // tell Rails we really want a put
			http.resultFormat = "text";
			return send(clazz, http, RailsEncoder.objectToRails(data, saveOptions), data)
		}
		
		static public function destroy(clazz:Class, data:Object, saveOptions:Object=null):AsyncToken {
			var http:HTTPService = new HTTPService();
			http.url = getBaseUrl(saveOptions)+"/"+ClassRegistry.resourceForClass(clazz)+"/"+data.id+".json";
			http.method = "POST";
			http.contentType = "application/json";						
			http.headers={X_HTTP_METHOD_OVERRIDE:'delete', 'X-HTTP-METHOD-OVERRIDE':'delete'}; // tell Rails we really want a delete
			http.resultFormat = "text";
			return send(clazz, http, RailsEncoder.objectToRails(data), data)  // FIXME: not sure resource needs to be sent
		}
		
		//-----------------------------------------------------------
		// INSTANCE METHODS
		//-----------------------------------------------------------
		
		public function save(saveOptions:Object=null):AsyncToken {
			if (this.id!=null) {
				return ActiveResource.update(ClassRegistry.classForResource(resourceName), this, saveOptions);
			} else {
				return ActiveResource.create(ClassRegistry.classForResource(resourceName), this, saveOptions);				
			}
		}
		
		public function destroy(saveOptions:Object=null):AsyncToken {
			return ActiveResource.destroy(ClassRegistry.classForResource(resourceName), this, saveOptions);
		}
		
		//-----------------------------------------------------------
		// DATA CONVERSION METHODS
		//-----------------------------------------------------------
		static public var send:Function = sendImplementation;   // Implementation can be switched during testing. FIXME: find a better way to test.
		
		static public function sendImplementation(resourceClazz:Class, service:HTTPService, params:Object=null, originalData:Object=null):AsyncToken {
			var call:AsyncToken = service.send(params);
			call.addResponder(new AsyncResponder(handleResult, handleFault));
			call.originalData = originalData; // token
			call.resourceClazz = resourceClazz				
			return call;			
		}
		
		static public function handleResult(event:ResultEvent, token:Object=null):void {
			// FIXME: add error mapping. At RailsDecoder or ActiveResource level?
			// FIXME: see how to reconnect  event.token.originalData
			var result:Object = RailsDecoder.from_rails(event.token.resourceClazz, event.result as String);
			event.mx_internal::setResult(result);
		}
		
		static protected function handleFault(fault:FaultEvent, token:Object=null):void {
			// FIXME: test other errors like 500
			if ([422, 404, 401, 400, 201].indexOf(fault.statusCode)>-1) {
				var json:String = fault.fault.content as String;
				var actionScript:Object = StringUtil.trim(json)!="" ? new JSONDecoder(json, /*strict*/true).getValue() : null;
				var railsErrors:RailsErrors = new RailsErrors(actionScript);
				if (fault.token.originalData) fault.token.originalData.errors = railsErrors;
				fault.fault.content =railsErrors;
			}
		}
		
		//-----------------------------------------------------------
		// HANDLE ERRORS
		//-----------------------------------------------------------
		
		/**
		 * map errors to originalData if present
		 */
		static protected function mapErrors(data:Object, originalData:Object):Object {
			var errors:Object = data ? data.errors : null;
			if (errors==null) return data;
			var resources:Array = BulkUtility.getAttributeNames(errors);
			for each (var resource:String in resources) {
				mapErrorsForResource(errors[resource], originalData[resource])
				
			}
			return originalData;	// FIXME: returning original data with errors replaced or shall we just return objects with errors?
		}
		
		static protected function mapErrorsForResource(errors:Object, objects:ArrayCollection):void {
			if (objects==null) return; // FIXME: check if that situation can occur.
			for each (var object:ActiveResource in objects) {  // clear errors
				object.errors = null;
			}
			var keys:Array = BulkUtility.getAttributeNames(errors);
			for each (var key:String in keys) {
				var originalResource:Object = objectForKey(key, objects)
				if (originalResource)  // Create errors attribute on resource 
					originalResource.errors = errors[key].data; // type:'invalid' FIXME: check if other types?
			}
		}
		
		/**
		 * Find object in list based on id or uid.
		 */
		static protected function objectForKey(key:Object, objects:ArrayCollection):Object {
			for each (var object:ActiveResource in objects) {
				if (object.id == key || object.uid == key) return object;
			}
			return null;
		}
		
		//-----------------------------------------------------------
		// ROUTING METHODS
		//-----------------------------------------------------------
		
		static protected function getBaseUrl(options:Object=null):String {
			var url:String = baseUrl;
			if (options&&options.nestedBy&&options.nestedBy is ActiveResource) {
				url += "/"+ClassRegistry.resourceForInstance(options.nestedBy)+"/"+options.nestedBy.id;
			}
			return url;
		}
		
		static protected function postFix(options:Object=null):String {
			return options&&options.postfix ? options.postfix : "";
		}
		
		//-----------------------------------------------------------
		// CLASS REGISTRY METHODS
		//-----------------------------------------------------------
		
		public function get resourceName():String {
			var className:String = getQualifiedClassName(this); // FIXME: we could cache the className/resourceName
			var clazz:Class = getDefinitionByName(className) as Class;
			return ClassRegistry.resourceForClass(clazz);
		}
		
		static protected function resource(resourceName:String, clazz:Class):void {
			ClassRegistry.resource(resourceName, clazz);
		}		
		
	}
}