from flask import request
from flask_server.app import flask_app, logger
from flask_server.app.tools.log_message_halper import log_request_msg
from flask_server.app.tools.system_handler import decorator_request, system_response, check_token
from flask_server.app.controllers import user


def get_json_from_request(required=False):
    try:
        json_data = request.get_json()
        return json_data
    except Exception as e:
        logger.error(
            log_request_msg(
                type_msg=e.__class__.__name__,
                msg=f"Couldn't get json: {str(e)}",
                source=request
            )
        )
        if required is True:
            raise e
        else:
            return None


@flask_app.route("/")
@check_token
@decorator_request
def index():
    return system_response(result="Hello world! {}".format(request.url_root))


@flask_app.route("/login/sms")
@decorator_request
def login_sms():
    phone = request.args['phone']
    return system_response(result=user.login_sms(phone))


@flask_app.route("/login")
@decorator_request
def login():
    sms_code = request.args['sms_code']
    current_phone = request.args['phone']
    confirmation_sms = user.sms_confirmation(current_phone, sms_code)
    if confirmation_sms['code'] is None:
        return system_response(result=user.login_user(current_phone))
    else:
        return system_response(result=confirmation_sms)