DATABASES = {
    "default": {
        "ATOMIC_REQUESTS": True,
        "ENGINE": "django.db.backends.postgresql",
        "NAME": "awx",
        "USER": "gateway",
        "PASSWORD": "gateway",
        "HOST": "aap_gw_db_pgsql_1",
        "PORT": "5432",
    }
}
CLUSTER_HOST_ID = "awx-test"
BROKER_URL = "redis://localhost:6379"
CACHES = {
    "default": {
        "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
    }
}
SECRET_KEY = "awxsecretkey"
ALLOWED_HOSTS = ["*"]
CSRF_TRUSTED_ORIGINS = ["https://localhost:8443"]
OPTIONAL_API_URLPATTERN_PREFIX = "controller"
